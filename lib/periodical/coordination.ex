defmodule Periodical.Coordination do
  @moduledoc false

  # Runs one occurrence's claim inside its callback task: the strategy delay,
  # the claim itself, the configured error policy, and lease renewal while the
  # callback runs. The scheduler builds the plan; nothing here blocks it.

  alias Periodical.Coordinator.Claim
  alias Periodical.{Config, Job, Recurrence, Telemetry}

  require Logger

  # A lease is this share of the gap to the next occurrence, so it has expired
  # before that occurrence is due; the rest is the margin for claim latency.
  @lease_share {9, 10}
  # A least-load delay never exceeds this share of the gap.
  @delay_share {1, 10}
  # Renewal checks at most this often, and at least this often for long leases.
  @min_renew_interval_ms 50
  @max_renew_interval_ms 30_000
  @utilization_window_ms 50

  @type plan :: %{
          claim: Claim.t(),
          error_policy: Config.coordinator_error_policy(),
          max_delay_ms: non_neg_integer(),
          load: Config.load_source() | nil,
          in_flight: float(),
          module: module(),
          options: keyword(),
          renew?: boolean()
        }

  @type outcome :: {:ran, term()} | {:skipped, :claim_lost | :claim_error}

  ##
  ## Public API
  ##

  @doc "Builds the claim plan for one occurrence, or `nil` when the schedule is not coordinated."
  @spec plan(Job.t(), DateTime.t(), Config.t(), non_neg_integer()) :: plan() | nil
  def plan(%Job{coordinate: false}, _scheduled_at, _config, _running), do: nil

  def plan(%Job{} = job, scheduled_at, config, running) do
    {module, options} = Config.coordinator(config)
    gap_ms = gap_ms(job, scheduled_at)
    {load, max_delay_ms} = strategy(Config.coordinator_strategy(config), gap_ms)

    %{
      claim: %Claim{
        key: job.coordination_key,
        name: job.name,
        scheduled_at: scheduled_at,
        token: token(),
        ttl_ms: ttl_ms(job, gap_ms, config)
      },
      error_policy: Config.coordinator_error(config),
      in_flight: min(running / Config.max_in_flight(config), 1.0),
      load: load,
      max_delay_ms: max_delay_ms,
      module: module,
      options: options,
      renew?: job.overlap == :skip and renews?(module)
    }
  end

  @doc "Runs `function` when the plan's claim is won (or not coordinated), reporting the outcome."
  @spec run(plan() | nil, (-> term())) :: outcome()
  def run(nil, function), do: {:ran, function.()}

  def run(plan, function) do
    plan |> delay_ms() |> Process.sleep()

    case claim(plan) do
      :won -> {:ran, with_renewal(plan, function)}
      :lost -> {:skipped, :claim_lost}
      :error when plan.error_policy == :run -> {:ran, function.()}
      :error -> {:skipped, :claim_error}
    end
  end

  @doc "Returns the lease for an occurrence whose next occurrence is `gap_ms` away (`nil` when none follows)."
  @spec lease_ms(pos_integer() | nil, pos_integer()) :: pos_integer()
  def lease_ms(nil, default_ms), do: default_ms
  def lease_ms(gap_ms, _default_ms), do: max(share(gap_ms, @lease_share), 1)

  @doc "Returns the least-load delay for a load fraction, bounded by `max_delay_ms`."
  @spec load_delay_ms(number(), non_neg_integer()) :: non_neg_integer()
  def load_delay_ms(load, max_delay_ms), do: round(clamp(load) * max_delay_ms)

  ##
  ## Private Functions
  ##

  # Plan construction

  # Reads the strategy into a load source and the delay bound for this occurrence.
  @spec strategy(Config.coordinator_strategy(), pos_integer() | nil) ::
          {Config.load_source() | nil, non_neg_integer()}
  defp strategy(:random, _gap_ms), do: {nil, 0}
  defp strategy({:least_load, load: load, max_delay_ms: max}, nil), do: {load, max}
  defp strategy({:least_load, load: load, max_delay_ms: max}, gap_ms), do: {load, min(max, share(gap_ms, @delay_share))}

  # Returns the time to the occurrence after this one, or nil for one-time and final occurrences.
  @spec gap_ms(Job.t(), DateTime.t()) :: pos_integer() | nil
  defp gap_ms(%Job{schedule: %{kind: :recurring, value: rule}}, scheduled_at) do
    case Recurrence.next(rule, scheduled_at) do
      {:ok, next_at} -> max(DateTime.diff(next_at, scheduled_at, :millisecond), 1)
      {:error, _error} -> nil
    end
  end

  defp gap_ms(_job, _scheduled_at), do: nil

  # Uses the schedule's explicit lease, else one derived from the gap.
  @spec ttl_ms(Job.t(), pos_integer() | nil, Config.t()) :: pos_integer()
  defp ttl_ms(%Job{claim_ttl_ms: ttl_ms}, _gap_ms, _config) when is_integer(ttl_ms), do: ttl_ms
  defp ttl_ms(_job, gap_ms, config), do: lease_ms(gap_ms, Config.default_claim_ttl_ms(config))

  # Generates a token unique to one claim attempt across the cluster.
  @spec token() :: String.t()
  defp token, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # Checks whether the coordinator can extend a lease.
  @spec renews?(module()) :: boolean()
  defp renews?(module), do: Code.ensure_loaded?(module) and function_exported?(module, :renew, 2)

  # Claiming

  # Computes how long this instance waits before claiming.
  @spec delay_ms(plan()) :: non_neg_integer()
  defp delay_ms(%{load: nil}), do: 0
  defp delay_ms(%{max_delay_ms: 0}), do: 0
  defp delay_ms(plan), do: load_delay_ms(read_load(plan), plan.max_delay_ms)

  # Reads the configured load measure as a number.
  @spec read_load(plan()) :: number()
  defp read_load(%{load: :in_flight, in_flight: in_flight}), do: in_flight

  defp read_load(%{load: :run_queue}),
    do: :erlang.statistics(:total_run_queue_lengths) / :erlang.system_info(:schedulers_online)

  defp read_load(%{load: :scheduler_utilization}) do
    sample = :scheduler.sample()
    Process.sleep(@utilization_window_ms)

    case List.keyfind(:scheduler.utilization(sample), :total, 0) do
      {:total, utilization, _percent} -> utilization
      nil -> 0.0
    end
  end

  defp read_load(%{load: {module, function, args}}) do
    case apply(module, function, args) do
      value when is_number(value) -> value
      _other -> 0.0
    end
  end

  # Calls the coordinator, treating a raise or exit as an error answer.
  @spec claim(plan()) :: :won | :lost | :error
  defp claim(plan) do
    started = System.monotonic_time()
    result = safely(fn -> plan.module.claim(plan.claim, plan.options) end)
    duration = System.monotonic_time() - started

    case result do
      answer when answer in [:won, :lost] ->
        Telemetry.coordinator_claim(duration, %{result: answer})
        answer

      other ->
        Telemetry.coordinator_claim(duration, %{result: :error})
        Logger.warning("Periodical claim failed, #{policy_text(plan.error_policy)}: #{inspect(other, limit: 20)}")
        :error
    end
  end

  # Describes the error policy for the warning.
  @spec policy_text(Config.coordinator_error_policy()) :: String.t()
  defp policy_text(:skip), do: "occurrence skipped"
  defp policy_text(:run), do: "running locally"

  # Runs an adapter call, converting a raise, throw, or exit into an error tuple.
  @spec safely((-> term())) :: term()
  defp safely(function) do
    function.()
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Renewal

  # Runs the callback, extending the lease from a linked process while it runs.
  @spec with_renewal(plan(), (-> term())) :: term()
  defp with_renewal(%{renew?: false}, function), do: function.()

  defp with_renewal(plan, function) do
    renewer = spawn_link(fn -> renew_loop(plan, deadline(plan.claim.ttl_ms)) end)

    try do
      function.()
    after
      Process.unlink(renewer)
      Process.exit(renewer, :kill)
    end
  end

  # Extends the lease whenever it would run out before the next check.
  @spec renew_loop(plan(), integer()) :: :ok
  defp renew_loop(plan, expires_at) do
    interval = renew_interval(plan.claim.ttl_ms)
    Process.sleep(interval)

    if expires_at - now() > 2 * interval do
      renew_loop(plan, expires_at)
    else
      renew_once(plan, 2 * interval)
    end
  end

  # Asks the coordinator for one extension and continues while the lease is ours.
  @spec renew_once(plan(), pos_integer()) :: :ok
  defp renew_once(plan, extension_ms) do
    case safely(fn -> plan.module.renew(%{plan.claim | ttl_ms: extension_ms}, plan.options) end) do
      :ok ->
        Telemetry.coordinator_renew(%{result: :ok})
        renew_loop(plan, deadline(extension_ms))

      :lost ->
        Telemetry.coordinator_renew(%{result: :lost})
        Logger.warning("Periodical lease was lost while its callback was still running")

      other ->
        Telemetry.coordinator_renew(%{result: :error})
        Logger.warning("Periodical lease renewal failed: #{inspect(other, limit: 20)}")
        renew_loop(plan, deadline(0))
    end
  end

  # Checks often enough to extend a lease before it lapses, but not constantly.
  @spec renew_interval(pos_integer()) :: pos_integer()
  defp renew_interval(ttl_ms), do: ttl_ms |> div(10) |> max(@min_renew_interval_ms) |> min(@max_renew_interval_ms)

  # Helpers

  @spec deadline(non_neg_integer()) :: integer()
  defp deadline(ms), do: now() + ms

  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)

  @spec share(pos_integer(), {pos_integer(), pos_integer()}) :: non_neg_integer()
  defp share(value, {numerator, denominator}), do: div(value * numerator, denominator)

  @spec clamp(number()) :: float()
  defp clamp(value), do: value |> max(0.0) |> min(1.0) |> Kernel.*(1.0)
end
