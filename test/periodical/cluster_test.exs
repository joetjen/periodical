defmodule Periodical.ClusterTest do
  # Several real Periodical instances, each on its own peer node with its own
  # scheduler and clock, sharing one lease store on the test node.
  use ExUnit.Case, async: false

  alias Periodical.Config
  alias PeriodicalTest.{ClusterCallbacks, LeaseStore, SkewedClock, StoreCoordinator}

  @moduletag :cluster
  @moduletag timeout: 60_000

  setup_all do
    {_output, 0} = System.cmd("epmd", ["-daemon"])

    unless Node.alive?() do
      {:ok, _pid} = Node.start(:"periodical_test_#{System.unique_integer([:positive])}@127.0.0.1", :longnames)
    end

    :ok
  end

  setup do
    start_supervised!(LeaseStore)
    :ok
  end

  test "without a coordinator every instance runs every occurrence" do
    for label <- [:a, :b, :c], do: start_instance(label, 0, [], "FREQ=SECONDLY")

    runs = collect(2_200)

    for label <- [:a, :b, :c] do
      assert Enum.count(runs, &(&1.label == label)) >= 2
    end
  end

  test "with a coordinator one instance runs each occurrence, whatever its clock skew" do
    settings = coordinated()

    start_instance(:a, 0, settings, "FREQ=SECONDLY")
    start_instance(:b, 120, settings, "FREQ=SECONDLY")
    start_instance(:c, -180, settings, "FREQ=SECONDLY")

    runs = collect(3_500)

    assert length(runs) in 2..5
    assert_spaced(runs, 800)
    assert length(runs) == Enum.count(LeaseStore.log(), &match?({:claim, :won, _, _, _, 900, _}, &1))
  end

  test "instances whose occurrences are offset by registration time still run once per period" do
    settings = coordinated()

    # Each instance anchors FREQ=SECONDLY;INTERVAL=2 at its own registration
    # second, so registering a second apart puts them on alternate seconds.
    start_instance(:even, 0, settings, "FREQ=SECONDLY;INTERVAL=2", fn -> await_second(0) end)
    start_instance(:odd, 0, settings, "FREQ=SECONDLY;INTERVAL=2", fn -> await_second(1) end)

    runs = collect(5_000)

    assert length(runs) in 2..3
    assert_spaced(runs, 1_700)

    scheduled = LeaseStore.log() |> Enum.map(&elem(&1, 4)) |> Enum.map(& &1.second) |> Enum.uniq()
    assert Enum.any?(scheduled, &(rem(&1, 2) == 0)) and Enum.any?(scheduled, &(rem(&1, 2) == 1))
  end

  test "when the winning instance dies, another takes over after its lease" do
    settings = coordinated()

    instances =
      for label <- [:first, :second], into: %{}, do: {label, start_instance(label, 0, settings, "FREQ=SECONDLY")}

    assert_receive {:ran, winner, _node, _scheduled_at, _ran_at}, 2_000
    {peer, _node} = Map.fetch!(instances, winner)
    :ok = :peer.stop(peer)
    [survivor] = Map.keys(instances) -- [winner]

    assert_receive {:ran, ^survivor, _node, _scheduled_at, _ran_at}, 3_000
  end

  # Starts one instance on a fresh peer node and registers the shared schedule.
  defp start_instance(label, clock_offset_ms, settings, expression, before_register \\ fn -> :ok end) do
    {:ok, peer, node} =
      :peer.start_link(%{name: :peer.random_name(~c"periodical"), host: ~c"127.0.0.1", longnames: true})

    :ok = :erpc.call(node, :code, :add_pathsa, [:code.get_path()])
    :ok = :erpc.call(node, Application, :put_env, [:periodical, :test_clock_offset_ms, clock_offset_ms])
    :ok = :erpc.call(node, Application, :put_env, [:periodical, Config, [clock_module: SkewedClock] ++ settings])
    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:periodical])
    :ok = :erpc.call(node, Logger, :configure, [[level: :warning]])

    before_register.()

    {:ok, _id} =
      :erpc.call(node, Periodical, :every, [expression, ClusterCallbacks, :record, [self(), label], [name: :shared]])

    {peer, node}
  end

  # Waits until 100 ms into the next wall-clock second with the given parity.
  defp await_second(parity) do
    now = System.os_time(:millisecond)
    next = (div(now, 1_000) + 1) * 1_000
    next = if rem(div(next, 1_000), 2) == parity, do: next, else: next + 1_000
    Process.sleep(next + 100 - now)
  end

  defp coordinated, do: [coordinator: {StoreCoordinator, store: Node.self()}]

  # Collects every run reported within the window, oldest first.
  defp collect(window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    collect_until(deadline, [])
  end

  defp collect_until(deadline, runs) do
    receive do
      {:ran, label, node, scheduled_at, ran_at} ->
        collect_until(deadline, [%{label: label, node: node, scheduled_at: scheduled_at, ran_at: ran_at} | runs])
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> Enum.sort_by(runs, & &1.ran_at)
    end
  end

  defp assert_spaced(runs, min_gap_ms) do
    gaps = runs |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b.ran_at - a.ran_at end)
    assert Enum.all?(gaps, &(&1 >= min_gap_ms)), "runs closer than #{min_gap_ms} ms: #{inspect(gaps)}"
  end
end
