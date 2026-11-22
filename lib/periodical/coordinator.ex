defmodule Periodical.Coordinator do
  @moduledoc """
  The contract for running a schedule on one instance of a cluster rather than on all.

  Without a coordinator, every BEAM instance that registers a schedule runs it.
  With one configured, the instances that share a named schedule compete for
  each run, and only the one that wins the claim executes the callback. The
  others count the occurrence as skipped with reason `:claim_lost`.

  Periodical does not implement a store and depends on none. It calls whatever
  module you configure, which keeps claims somewhere every instance can reach:

      config :periodical, Periodical.Config,
        coordinator: {PeriodicalRedis, connection: MyApp.Redix}

  Ready-made adapters are separate packages:

  - [`periodical_redis`](https://hex.pm/packages/periodical_redis): Redis or
    KeyDB, one `SET NX PX` per claim.
  - [`periodical_ecto`](https://hex.pm/packages/periodical_ecto): a table in
    PostgreSQL or MariaDB/MySQL through an Ecto repository.

  ## Which schedules are coordinated

  A claim needs a key that is the same on every instance, and schedule ids are
  local, so only **named** schedules are coordinated. With a coordinator
  configured, a schedule registered with `:name` is coordinated unless it
  passes `coordinate: false`; one without a name runs locally on every
  instance, as before. Passing `coordinate: true` without a name, or without a
  configured coordinator, is rejected at registration.

  ## Claims are leases on the schedule

  A claim is keyed on the schedule's name, not on the occurrence's time, and it
  is held for a lease (`ttl_ms`) rather than released when the callback
  returns. While the lease lasts, every other instance loses.

  This is deliberate. Recurrence rules that leave fields open take them from
  the moment of registration (`FREQ=MINUTELY;INTERVAL=5` registered at 09:01
  fires at 09:06, registered at 09:03 at 09:08), and instance clocks drift, so
  instances generally do not agree on an occurrence's exact time. A lease on
  the name works whatever they believe: the first instance to fire takes the
  run, and the others fire into its lease and lose.

  The lease for a recurring occurrence is 90% of the gap to the schedule's
  next occurrence, so it expires before the following run is due. A one-time
  schedule, or a recurring schedule's final occurrence, holds
  `:default_claim_ttl_ms` (one minute unless configured). A schedule's
  `:claim_ttl_ms` option overrides both.

  The lease is measured by the store's clock, so instance clock skew does not
  shorten or lengthen it. Skew and registration offsets up to the lease are
  covered: within one lease, only one instance runs.

  ## Failure

  An instance that wins and then dies does not release its claim; the lease
  expires and the next occurrence is claimed by whichever instance fires
  first. The occurrence the dead instance won is not run again: Periodical
  owns no retries and no durable delivery.

  A callback that outlasts its lease, on a schedule with `overlap: :skip`, has
  its lease extended while it runs (when the coordinator implements
  `c:renew/2`), so no other instance starts the next occurrence over it. The
  extension is short and stops with the callback.

  A claim that fails with an error, or raises, follows `:coordinator_error`:
  `:skip` (the default) skips the occurrence with reason `:claim_error`,
  `:run` runs it locally anyway. Either way a warning is logged and the
  `[:periodical, :coordinator, :claim]` event carries `result: :error`.

  ## Strategies

  `:coordinator_strategy` decides how instances compete:

  - `:random` (the default) claims at once. Whichever instance reaches the
    store first wins, which in practice is arbitrary.
  - `:least_load` delays each claim in proportion to the instance's load, so
    the least loaded instance tends to claim first. The delay is at most
    `:max_delay_ms` (250 by default, never more than 5 000) and never more than
    a tenth of the gap between occurrences. `:load` picks the measure, each
    read as a fraction from 0.0 to 1.0:

    - `:in_flight` (the default): running callbacks over `:max_in_flight`.
    - `:run_queue`: the VM's run queue length per online scheduler, capped at 1.
    - `:scheduler_utilization`: scheduler utilization sampled over 50 ms.
    - `{module, function, args}`: your own function, returning a number;
      values outside 0.0..1.0 are clamped.

        config :periodical, Periodical.Config,
          coordinator: {PeriodicalRedis, connection: MyApp.Redix},
          coordinator_strategy: {:least_load, load: :run_queue, max_delay_ms: 200}

  The claim runs in the callback's task, before the callback, so it counts
  against `:max_in_flight` and the callback's `:execution_timeout_ms`.

  ## Implementing a coordinator

  `c:claim/2` must be atomic: of any number of concurrent claims for the same
  key whose lease has expired or never existed, exactly one may return `:won`.
  The claim's `:token` is unique to the attempt; store it so `c:renew/2` can
  tell its own lease from a later winner's.
  """

  alias Periodical.Coordinator.Claim

  @doc """
  Attempts to take the lease on `claim.key` for `claim.ttl_ms` milliseconds.

  Returns `:won` when this attempt holds the lease, `:lost` when another
  attempt's lease is still running, or `{:error, reason}` when the store could
  not decide. `options` are the keyword options given with the configured
  module.
  """
  @callback claim(Claim.t(), keyword()) :: :won | :lost | {:error, term()}

  @doc """
  Extends a lease this attempt still holds to `claim.ttl_ms` from now.

  Returns `:lost` when the lease expired and was taken by another attempt (or
  no longer exists). Optional: without it, a long callback's lease simply
  expires.
  """
  @callback renew(Claim.t(), keyword()) :: :ok | :lost | {:error, term()}

  @optional_callbacks renew: 2

  ##
  ## Public API
  ##

  @doc """
  Returns the store key for a schedule name.

  The key is the lowercase hex SHA-256 of the name's deterministic external
  term format, so it is the same on every instance and release, always 64
  bytes long, and safe in any store. Adapters add their own prefix.

      iex> key = Periodical.Coordinator.key(:nightly_report)
      iex> {byte_size(key), key == Periodical.Coordinator.key(:nightly_report)}
      {64, true}
  """
  @spec key(Periodical.schedule_name()) :: String.t()
  def key(name) when is_atom(name) or is_tuple(name) do
    name
    |> :erlang.term_to_binary([:deterministic, minor_version: 2])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

defmodule Periodical.Coordinator.Claim do
  @moduledoc """
  One attempt to take the lease for a coordinated schedule.

  - `:key` — the schedule's store key, `Periodical.Coordinator.key/1` of its name.
  - `:name` — the schedule name itself, for adapters that record it for operators.
  - `:scheduled_at` — the occurrence this instance is about to run, as this
    instance computed it.
  - `:ttl_ms` — how long the lease lasts from now, in milliseconds.
  - `:token` — unique to this attempt; the lease holder's identity.
  """

  @enforce_keys [:key, :name, :scheduled_at, :token, :ttl_ms]
  defstruct @enforce_keys

  @typedoc "One claim attempt."
  @type t :: %__MODULE__{
          key: String.t(),
          name: Periodical.schedule_name(),
          scheduled_at: DateTime.t(),
          token: String.t(),
          ttl_ms: pos_integer()
        }
end
