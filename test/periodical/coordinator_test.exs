defmodule Periodical.CoordinatorTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Periodical.{Config, Coordination, Coordinator}
  alias PeriodicalTest.{ClaimOnlyCoordinator, ClusterCallbacks, LeaseStore, StoreCoordinator}

  import ExUnit.CaptureLog

  doctest Periodical.Coordinator

  setup do
    start_supervised!(LeaseStore)
    on_exit(fn -> restart_periodical([]) end)
    :ok
  end

  describe "configuration" do
    test "accepts a module, a module with options, and the strategy shorthands" do
      assert {:ok, config} = Config.new(coordinator: StoreCoordinator)
      assert Config.coordinator(config) == {StoreCoordinator, []}
      assert Config.coordinator_strategy(config) == :random
      assert Config.coordinator_error(config) == :skip

      assert {:ok, config} = Config.new(coordinator: {StoreCoordinator, store: :n@h}, coordinator_strategy: :least_load)
      assert Config.coordinator(config) == {StoreCoordinator, [store: :n@h]}
      assert Config.coordinator_strategy(config) == {:least_load, load: :in_flight, max_delay_ms: 250}

      assert {:ok, config} =
               Config.new(coordinator_strategy: {:least_load, load: {:erlang, :system_time, []}, max_delay_ms: 10})

      assert Config.coordinator_strategy(config) == {:least_load, load: {:erlang, :system_time, []}, max_delay_ms: 10}
    end

    test "rejects modules without claim/2 and unbounded or unknown strategies" do
      assert {:error, %{code: :invalid_config}} = Config.new(coordinator: String)
      assert {:error, %{code: :invalid_config}} = Config.new(coordinator: {StoreCoordinator, :bad})
      assert {:error, %{code: :invalid_config}} = Config.new(coordinator: "redis")
      assert {:error, %{code: :invalid_config}} = Config.new(coordinator_error: :retry)
      assert {:error, %{code: :invalid_config}} = Config.new(coordinator_strategy: :fastest)
      assert {:error, %{code: :invalid_config}} = Config.new(coordinator_strategy: {:least_load, max_delay_ms: 5_001})
      assert {:error, %{code: :invalid_config}} = Config.new(coordinator_strategy: {:least_load, load: :moon})

      assert {:error, %{code: :invalid_config}} =
               Config.new(coordinator_strategy: {:least_load, load: {:erlang, :nope, []}})

      assert {:error, %{code: :invalid_config}} = Config.new(coordinator_strategy: {:least_load, extra: 1})
      assert {:error, %{code: :invalid_config}} = Config.new(default_claim_ttl_ms: 0)
    end
  end

  describe "which schedules are coordinated" do
    test "named schedules claim, unnamed ones and coordinate: false run locally" do
      restart_periodical(coordinator: StoreCoordinator)
      at = soon()

      assert {:ok, _id} = Periodical.once(at, ClusterCallbacks, :record, [self(), :named], name: :named)
      assert {:ok, _id} = Periodical.once(at, ClusterCallbacks, :record, [self(), :unnamed])

      assert {:ok, _id} =
               Periodical.once(at, ClusterCallbacks, :record, [self(), :opted_out], name: :opted_out, coordinate: false)

      for label <- [:named, :unnamed, :opted_out], do: assert_receive({:ran, ^label, _, _, _}, 500)

      assert [{:claim, :won, _node, key, ^at, 60_000, _now}] = LeaseStore.log()
      assert key == Coordinator.key(:named)
    end

    test "coordinate: true needs a name and a configured coordinator" do
      restart_periodical([])
      at = soon()

      assert {:error, %{code: :invalid_schedule, details: %{field: :coordinate, expected: :configured_coordinator}}} =
               Periodical.once(at, ClusterCallbacks, :record, [self(), :x], name: :x, coordinate: true)

      restart_periodical(coordinator: StoreCoordinator)

      assert {:error, %{code: :invalid_schedule, details: %{field: :coordinate, expected: :named_schedule}}} =
               Periodical.once(at, ClusterCallbacks, :record, [self(), :x], coordinate: true)

      assert {:error, %{details: %{field: :coordinate}}} =
               Periodical.once(at, ClusterCallbacks, :record, [self(), :x], name: :x, coordinate: :yes)

      assert {:error, %{details: %{field: :claim_ttl_ms}}} =
               Periodical.once(at, ClusterCallbacks, :record, [self(), :x], name: :x, claim_ttl_ms: 0)
    end
  end

  describe "claim outcomes" do
    test "a lost claim skips the occurrence with reason :claim_lost" do
      restart_periodical(coordinator: StoreCoordinator)
      attach([[:periodical, :trigger, :skipped], [:periodical, :coordinator, :claim]])

      # Another instance already holds the lease on this schedule.
      held = claim_for(:contested, 60_000)
      assert :won = StoreCoordinator.claim(held, [])

      assert {:ok, _id} = Periodical.once(soon(), ClusterCallbacks, :record, [self(), :contested], name: :contested)

      assert_receive {:event, [:periodical, :coordinator, :claim], %{count: 1, duration: _}, %{result: :lost}}, 500
      assert_receive {:event, [:periodical, :trigger, :skipped], %{count: 1}, %{reason: :claim_lost}}, 500
      refute_received {:ran, :contested, _, _, _}
      assert_eventually_empty()
    end

    test "a claim error skips by default, logged and counted" do
      restart_periodical(coordinator: StoreCoordinator)
      attach([[:periodical, :trigger, :skipped], [:periodical, :coordinator, :claim]])
      :ok = LeaseStore.mode(:error)

      log =
        capture_log(fn ->
          assert {:ok, _id} = Periodical.once(soon(), ClusterCallbacks, :record, [self(), :failing], name: :failing)
          assert_receive {:event, [:periodical, :trigger, :skipped], _, %{reason: :claim_error}}, 500
        end)

      assert_received {:event, [:periodical, :coordinator, :claim], _, %{result: :error}}
      assert log =~ "claim failed, occurrence skipped"
      refute_received {:ran, :failing, _, _, _}
    end

    test "coordinator_error: :run runs locally when the coordinator raises" do
      restart_periodical(coordinator: StoreCoordinator, coordinator_error: :run)
      :ok = LeaseStore.mode(:raise)

      log =
        capture_log(fn ->
          assert {:ok, _id} = Periodical.once(soon(), ClusterCallbacks, :record, [self(), :local], name: :local)
          assert_receive {:ran, :local, _, _, _}, 500
        end)

      assert log =~ "running locally"
      assert log =~ "store exploded"
    end

    test "an explicit claim_ttl_ms overrides the derived lease" do
      restart_periodical(coordinator: StoreCoordinator)
      at = soon()

      assert {:ok, _id} =
               Periodical.once(at, ClusterCallbacks, :record, [self(), :ttl], name: :ttl, claim_ttl_ms: 1_234)

      assert_receive {:ran, :ttl, _, _, _}, 500
      assert [{:claim, :won, _, _, ^at, 1_234, _}] = LeaseStore.log()
    end

    test "a recurring lease is 90% of the gap to the next occurrence" do
      restart_periodical(coordinator: StoreCoordinator)

      assert {:ok, _id} =
               Periodical.every("FREQ=SECONDLY", ClusterCallbacks, :record, [self(), :every_second],
                 name: :every_second
               )

      assert_receive {:ran, :every_second, _, _, _}, 1_500
      assert [{:claim, :won, _, _, _, 900, _} | _] = LeaseStore.log()
    end

    test "consecutive occurrences inside one lease run once" do
      restart_periodical(coordinator: StoreCoordinator)

      # A lease longer than the gap: the next second fires into it and loses.
      assert {:ok, _id} =
               Periodical.every("FREQ=SECONDLY", ClusterCallbacks, :record, [self(), :held],
                 name: :held,
                 claim_ttl_ms: 60_000
               )

      assert_receive {:ran, :held, _, _, _}, 1_500
      refute_receive {:ran, :held, _, _, _}, 1_500
      assert [{:claim, :won, _, _, _, _, _}, {:claim, :lost, _, _, _, _, _} | _] = LeaseStore.log()
    end
  end

  describe "lease renewal" do
    test "a long callback with overlap: :skip extends its lease while it runs" do
      restart_periodical(coordinator: StoreCoordinator)
      attach([[:periodical, :coordinator, :renew]])

      assert {:ok, _id} =
               Periodical.once(soon(), ClusterCallbacks, :linger, [self(), :long, 600],
                 name: :long,
                 claim_ttl_ms: 200
               )

      assert_receive {:finished, :long, _}, 1_500
      assert_received {:event, [:periodical, :coordinator, :renew], %{count: 1}, %{result: :ok}}

      renewals = for {:renew, :ok, _key, ttl_ms, _now} <- LeaseStore.log(), do: ttl_ms
      assert renewals != []
      assert Enum.all?(renewals, &(&1 == 100))

      # Renewal stops with the callback, so the lease runs out shortly after.
      Process.sleep(150)
      assert :won = StoreCoordinator.claim(claim_for(:long, 1_000), [])
    end

    test "coordinators without renew/2 and overlap: :allow schedules do not renew" do
      restart_periodical(coordinator: ClaimOnlyCoordinator)

      assert {:ok, _id} =
               Periodical.once(soon(), ClusterCallbacks, :linger, [self(), :no_renew, 300],
                 name: :no_renew,
                 claim_ttl_ms: 100
               )

      assert_receive {:finished, :no_renew, _}, 1_000

      restart_periodical(coordinator: StoreCoordinator)

      assert {:ok, _id} =
               Periodical.once(soon(), ClusterCallbacks, :linger, [self(), :allow, 300],
                 name: :allow,
                 claim_ttl_ms: 100,
                 overlap: :allow
               )

      assert_receive {:finished, :allow, _}, 1_000
      assert for({:renew, _, _, _, _} <- LeaseStore.log(), do: :renewed) == []
    end
  end

  describe "least-load strategy" do
    test "delays the claim in proportion to the load" do
      restart_periodical(
        coordinator: StoreCoordinator,
        coordinator_strategy: {:least_load, load: {__MODULE__, :full_load, []}, max_delay_ms: 300}
      )

      at = soon()
      assert {:ok, _id} = Periodical.once(at, ClusterCallbacks, :record, [self(), :loaded], name: :loaded)
      assert_receive {:ran, :loaded, _, ^at, ran_at}, 1_000
      assert ran_at - DateTime.to_unix(at, :millisecond) >= 300
    end

    test "the delay never exceeds a tenth of the gap" do
      {:ok, config} =
        Config.new(
          coordinator: StoreCoordinator,
          coordinator_strategy: {:least_load, load: :run_queue, max_delay_ms: 5_000}
        )

      {:ok, job} = job(config, "FREQ=SECONDLY", name: :tight)
      plan = Coordination.plan(job, ~U[2026-01-01 00:00:00Z], config, 0)
      assert plan.max_delay_ms == 100
      assert plan.claim.ttl_ms == 900
    end
  end

  describe "properties" do
    property "a recurring lease is positive and shorter than its gap" do
      check all(gap_ms <- integer(2..100_000_000)) do
        lease = Coordination.lease_ms(gap_ms, 60_000)
        assert lease > 0 and lease < gap_ms
      end
    end

    property "the least-load delay stays within its bound for any load" do
      check all(load <- one_of([float(), integer()]), max_delay_ms <- integer(0..5_000)) do
        assert Coordination.load_delay_ms(load, max_delay_ms) in 0..max_delay_ms
      end
    end

    property "keys are 64 lowercase hex bytes and differ between names" do
      check all(a <- schedule_name(), b <- schedule_name()) do
        key = Coordinator.key(a)
        assert key =~ ~r/\A[0-9a-f]{64}\z/
        assert key == Coordinator.key(a)
        if a != b, do: assert(key != Coordinator.key(b))
      end
    end
  end

  @doc false
  def full_load, do: 1.0

  @doc false
  def forward_event(event, measurements, metadata, recipient),
    do: send(recipient, {:event, event, measurements, metadata})

  defp schedule_name do
    one_of([
      atom(:alphanumeric),
      map(list_of(one_of([atom(:alphanumeric), integer(), binary()]), max_length: 7), &List.to_tuple/1)
    ])
  end

  defp job(config, expression, options) do
    {:ok, schedule} = Periodical.Schedule.recurring(expression)
    Periodical.Job.new(1, schedule, ClusterCallbacks, :record, [self(), :x], options, config, ~U[2025-12-31 23:59:59Z])
  end

  defp claim_for(name, ttl_ms) do
    %Coordinator.Claim{
      key: Coordinator.key(name),
      name: name,
      scheduled_at: DateTime.utc_now(),
      token: "other-instance",
      ttl_ms: ttl_ms
    }
  end

  defp soon, do: DateTime.add(DateTime.utc_now(), 40, :millisecond)

  defp attach(events) do
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(handler, events, &__MODULE__.forward_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp restart_periodical(settings) do
    _ignored = Application.stop(:periodical)
    :ok = Application.put_env(:periodical, Config, settings)
    {:ok, _applications} = Application.ensure_all_started(:periodical)
    :ok
  end

  defp assert_eventually_empty(attempts \\ 30)
  defp assert_eventually_empty(0), do: flunk("Periodical did not become empty")

  defp assert_eventually_empty(attempts) do
    case Periodical.stats() do
      %{in_flight: 0, pending: 0, schedules: 0} ->
        :ok

      _busy ->
        Process.sleep(10)
        assert_eventually_empty(attempts - 1)
    end
  end
end
