defmodule PeriodicalTest.LeaseStore do
  @moduledoc false

  # An in-memory lease store with the semantics a real coordinator store must
  # have: one atomic decision per claim, leases measured by the store's own
  # clock. Multi-instance tests run one on the test node and point every peer's
  # coordinator at it. `mode/1` makes it misbehave on purpose.

  use GenServer

  alias Periodical.Coordinator.Claim

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_options \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc false
  @spec claim(node(), Claim.t()) :: :won | :lost | {:error, term()}
  def claim(node, claim), do: GenServer.call({__MODULE__, node}, {:claim, claim, Node.self()})

  @doc false
  @spec renew(node(), Claim.t()) :: :ok | :lost | {:error, term()}
  def renew(node, claim), do: GenServer.call({__MODULE__, node}, {:renew, claim})

  @doc "Sets how claims are answered: `:normal`, `:error`, `:raise`, or `:slow`."
  @spec mode(atom()) :: :ok
  def mode(mode), do: GenServer.call(__MODULE__, {:mode, mode})

  @doc "Returns every call received, oldest first."
  @spec log() :: [tuple()]
  def log, do: GenServer.call(__MODULE__, :log)

  @impl true
  def init(:ok), do: {:ok, %{leases: %{}, log: [], mode: :normal}}

  @impl true
  def handle_call({:mode, mode}, _from, state), do: {:reply, :ok, %{state | mode: mode}}
  def handle_call(:log, _from, state), do: {:reply, Enum.reverse(state.log), state}

  def handle_call({:claim, _claim, _from_node}, _from, %{mode: :error} = state),
    do: {:reply, {:error, :store_down}, state}

  def handle_call({:claim, _claim, _from_node}, _from, %{mode: :raise} = state),
    do: {:reply, :raise, state}

  def handle_call({:claim, %Claim{} = claim, from_node}, _from, state) do
    now = now()

    {answer, leases} =
      case Map.get(state.leases, claim.key) do
        {_token, expires_at} when expires_at > now -> {:lost, state.leases}
        _expired_or_free -> {:won, Map.put(state.leases, claim.key, {claim.token, now + claim.ttl_ms})}
      end

    entry = {:claim, answer, from_node, claim.key, claim.scheduled_at, claim.ttl_ms, now}
    {:reply, answer, %{state | leases: leases, log: [entry | state.log]}}
  end

  def handle_call({:renew, %Claim{} = claim}, _from, state) do
    now = now()

    {answer, leases} =
      case Map.get(state.leases, claim.key) do
        {token, expires_at} when token == claim.token and expires_at > now ->
          {:ok, Map.put(state.leases, claim.key, {token, now + claim.ttl_ms})}

        _other ->
          {:lost, state.leases}
      end

    {:reply, answer, %{state | leases: leases, log: [{:renew, answer, claim.key, claim.ttl_ms, now} | state.log]}}
  end

  defp now, do: System.monotonic_time(:millisecond)
end

defmodule PeriodicalTest.StoreCoordinator do
  @moduledoc false

  # A coordinator backed by `PeriodicalTest.LeaseStore` on the node given as
  # `:store` (the local node by default).

  alias PeriodicalTest.LeaseStore

  @behaviour Periodical.Coordinator

  @impl true
  def claim(claim, options) do
    case LeaseStore.claim(Keyword.get(options, :store, Node.self()), claim) do
      :raise -> raise "store exploded"
      answer -> answer
    end
  end

  @impl true
  def renew(claim, options), do: LeaseStore.renew(Keyword.get(options, :store, Node.self()), claim)
end

defmodule PeriodicalTest.ClaimOnlyCoordinator do
  @moduledoc false

  # A coordinator without the optional renew callback.

  @behaviour Periodical.Coordinator

  @impl true
  def claim(claim, options), do: PeriodicalTest.StoreCoordinator.claim(claim, options)
end

defmodule PeriodicalTest.SkewedClock do
  @moduledoc false

  # The system clock shifted by `:test_clock_offset_ms` from the
  # `:periodical` environment, to give each peer its own clock skew.

  @behaviour Periodical.Clock

  @impl true
  def now(time_zone) do
    with {:ok, now} <- DateTime.now(time_zone) do
      {:ok, DateTime.add(now, Application.get_env(:periodical, :test_clock_offset_ms, 0), :millisecond)}
    end
  end
end

defmodule PeriodicalTest.ClusterCallbacks do
  @moduledoc false

  @doc false
  @spec record(Periodical.Trigger.t(), pid(), term()) :: :ok
  def record(trigger, recipient, label) do
    send(recipient, {:ran, label, Node.self(), trigger.scheduled_at, System.os_time(:millisecond)})
    :ok
  end

  @doc false
  @spec linger(Periodical.Trigger.t(), pid(), term(), non_neg_integer()) :: :ok
  def linger(trigger, recipient, label, duration_ms) do
    record(trigger, recipient, label)
    Process.sleep(duration_ms)
    send(recipient, {:finished, label, Node.self()})
    :ok
  end
end
