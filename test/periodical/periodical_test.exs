defmodule PeriodicalTest.Support do
  @moduledoc false

  @doc false
  @spec notify(Periodical.Trigger.t(), pid(), term()) :: :ok
  def notify(trigger, recipient, message) do
    send(recipient, {:triggered, trigger, message})
    :ok
  end

  @doc false
  @spec block(Periodical.Trigger.t(), pid(), term()) :: :ok
  def block(trigger, recipient, marker) do
    send(recipient, {:started, trigger, marker, self()})

    receive do
      :continue -> :ok
    end
  end

  @doc false
  @spec fail(Periodical.Trigger.t(), pid()) :: no_return()
  def fail(_trigger, recipient) do
    send(recipient, :attempted)
    raise "expected callback failure"
  end
end

defmodule PeriodicalTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Periodical.Recurrence
  alias Periodical.{Config, Schedule, Stats, Trigger}
  alias PeriodicalTest.Support

  doctest Periodical
  doctest Periodical.Schedule

  setup do
    restart_periodical([])
    :ok
  end

  describe "configuration" do
    test "loads bounded defaults and exposes the build environment" do
      assert {:ok, config} = Config.new([])
      assert Config.max_schedules(config) > 0
      assert Config.max_pending_triggers(config) > 0
      assert Config.max_in_flight(config) > 0
      assert Config.mix_env() == :test
      assert Config.test?()
    end

    test "rejects malformed, unknown, and inconsistent settings" do
      assert {:error, %{code: :invalid_config}} = Config.new(unknown: true)
      assert {:error, %{code: :invalid_config}} = Config.new(max_in_flight: 0)

      assert {:error, %{code: :invalid_config}} =
               Config.new(default_execution_timeout_ms: 20, max_execution_timeout_ms: 10)
    end
  end

  describe "pure schedule calculation" do
    test "parses recurring strings and preserves anchored cadence" do
      reference = ~U[2026-07-19 12:00:00Z]
      assert {:ok, schedule} = Schedule.recurring("FREQ=SECONDLY;INTERVAL=30")
      assert {:ok, first} = Schedule.next(schedule, reference)
      assert first == ~U[2026-07-19 12:00:30Z]

      now = ~U[2026-07-19 12:00:35Z]
      assert {:ok, second} = Schedule.following(schedule, first, now)
      assert second == ~U[2026-07-19 12:01:00Z]
    end

    test "rejects one-time instants that are not strictly in the future" do
      reference = ~U[2026-07-19 12:00:00Z]
      assert {:error, %{code: :invalid_schedule}} = Schedule.once(reference, reference)
    end

    property "calculated interval delays are always positive" do
      check all(seconds <- integer(1..86_400)) do
        reference = ~U[2026-07-19 12:00:00Z]
        assert {:ok, recurrence} = Recurrence.parse("FREQ=SECONDLY;INTERVAL=#{seconds}")
        assert {:ok, schedule} = Schedule.recurring(recurrence)
        assert {:ok, next_at} = Schedule.next(schedule, reference)
        assert Schedule.delay_ms(next_at, reference) == seconds * 1_000
      end
    end
  end

  describe "registration and execution" do
    test "runs a one-time MFA with a typed occurrence payload" do
      occurrence = DateTime.add(DateTime.utc_now(), 40, :millisecond)
      assert {:ok, id} = Periodical.once(occurrence, Support, :notify, [self(), :verified])

      assert_receive {:triggered, %Trigger{schedule_id: ^id, kind: :once}, :verified}, 300
      assert_eventually_empty()
    end

    test "accepts recurrence structs and strings but rejects invalid callbacks" do
      assert {:ok, recurrence} = Recurrence.parse("FREQ=SECONDLY")
      assert {:ok, first} = Periodical.every(recurrence, Support, :notify, [self(), :struct])
      assert {:ok, second} = Periodical.every("FREQ=SECONDLY", Support, :notify, [self(), :string])
      assert {:error, %{code: :invalid_schedule}} = Periodical.every(recurrence, Support, :missing)
      assert :ok = Periodical.cancel(first)
      assert :ok = Periodical.cancel(second)
    end

    test "enforces schedule capacity and live unique names" do
      restart_periodical(max_schedules: 1)
      occurrence = DateTime.add(DateTime.utc_now(), 1, :second)

      assert {:ok, _id} = Periodical.once(occurrence, Support, :notify, [self(), :first], name: :unique)
      assert {:error, %{code: :overloaded}} = Periodical.once(occurrence, Support, :notify, [self(), :full])

      restart_periodical(max_schedules: 2)
      assert {:ok, _id} = Periodical.once(occurrence, Support, :notify, [self(), :first], name: :unique)

      assert {:error, %{code: :duplicate_name}} =
               Periodical.once(occurrence, Support, :notify, [self(), :duplicate], name: :unique)
    end
  end

  describe "control and bounded callback ownership" do
    test "drain waits for active callbacks and closes registration" do
      occurrence = DateTime.add(DateTime.utc_now(), 30, :millisecond)
      assert {:ok, _id} = Periodical.once(occurrence, Support, :block, [self(), :draining])
      assert_receive {:started, %Trigger{}, :draining, worker}, 250

      drain = Task.async(fn -> Periodical.drain(200) end)
      refute Task.yield(drain, 20)
      send(worker, :continue)
      assert Task.await(drain) == :ok

      later = DateTime.add(DateTime.utc_now(), 1, :second)
      assert {:error, %{code: :shutting_down}} = Periodical.once(later, Support, :notify, [self(), :rejected])
    end

    test "drain returns a structured timeout and leaves registration closed" do
      occurrence = DateTime.add(DateTime.utc_now(), 30, :millisecond)
      assert {:ok, _id} = Periodical.once(occurrence, Support, :block, [self(), :timeout])
      assert_receive {:started, %Trigger{}, :timeout, worker}, 250

      assert {:error, %{code: :drain_timeout}} = Periodical.drain(20)
      later = DateTime.add(DateTime.utc_now(), 1, :second)
      assert {:error, %{code: :shutting_down}} = Periodical.once(later, Support, :notify, [self(), :rejected])
      send(worker, :continue)
    end

    test "pause removes the active timer and resume applies fire-once policy" do
      occurrence = DateTime.add(DateTime.utc_now(), 40, :millisecond)

      assert {:ok, id} =
               Periodical.once(occurrence, Support, :notify, [self(), :resumed],
                 name: :pausable,
                 misfire: :fire_once
               )

      assert :ok = Periodical.pause(:pausable)
      refute_receive {:triggered, _, :resumed}, 70
      assert :ok = Periodical.resume(id)
      assert_receive {:triggered, %Trigger{schedule_id: ^id}, :resumed}, 200
    end

    test "cancel terminates running callbacks and frees their schedule names" do
      occurrence = DateTime.add(DateTime.utc_now(), 30, :millisecond)
      assert {:ok, id} = Periodical.once(occurrence, Support, :block, [self(), :cancel], name: :running)
      assert_receive {:started, %Trigger{schedule_id: ^id}, :cancel, worker}, 250
      assert :ok = Periodical.cancel(:running)
      refute Process.alive?(worker)
      assert {:error, %{code: :schedule_not_found}} = Periodical.cancel(id)
    end

    test "an execution timeout releases global callback capacity" do
      restart_periodical(max_in_flight: 1, default_execution_timeout_ms: 30)
      first_at = DateTime.add(DateTime.utc_now(), 30, :millisecond)
      second_at = DateTime.add(first_at, 5, :millisecond)

      assert {:ok, _first} = Periodical.once(first_at, Support, :block, [self(), :timeout])
      assert {:ok, _second} = Periodical.once(second_at, Support, :notify, [self(), :after_timeout])
      assert_receive {:started, %Trigger{}, :timeout, _worker}, 250
      assert_receive {:triggered, %Trigger{}, :after_timeout}, 300
      assert_eventually_empty()
    end

    test "callback failures are terminal and are not retried" do
      occurrence = DateTime.add(DateTime.utc_now(), 30, :millisecond)
      assert {:ok, _id} = Periodical.once(occurrence, Support, :fail, [self()])
      assert_receive :attempted, 250
      refute_receive :attempted, 100
      assert_eventually_empty()
    end
  end

  describe "observability" do
    test "exposes count-only stats and canonical terminal telemetry" do
      handler = {__MODULE__, make_ref()}

      assert :ok =
               :telemetry.attach(
                 handler,
                 [:periodical, :trigger, :terminal],
                 &__MODULE__.forward_event/4,
                 self()
               )

      on_exit(fn -> :telemetry.detach(handler) end)
      occurrence = DateTime.add(DateTime.utc_now(), 30, :millisecond)
      assert {:ok, _id} = Periodical.once(occurrence, Support, :notify, [self(), :telemetry])
      assert %Stats{schedule_capacity: capacity, schedules: 1} = Periodical.stats()
      assert capacity > 0
      assert_receive {:triggered, %Trigger{}, :telemetry}, 250

      assert_receive {:event, [:periodical, :trigger, :terminal], %{count: 1}, %{result: :ok}},
                     250
    end
  end

  @doc false
  @spec forward_event([atom(), ...], map(), map(), pid()) :: :ok
  def forward_event(event, measurements, metadata, recipient) do
    send(recipient, {:event, event, measurements, metadata})
    :ok
  end

  # Restarts the OTP application with isolated in-memory configuration.
  @spec restart_periodical(keyword()) :: :ok
  defp restart_periodical(settings) do
    _ignored = Application.stop(:periodical)
    :ok = Application.put_env(:periodical, Config, settings)
    {:ok, _applications} = Application.ensure_all_started(:periodical)
    :ok
  end

  # Waits for terminal cleanup through the public count-only state boundary.
  @spec assert_eventually_empty(non_neg_integer()) :: :ok
  defp assert_eventually_empty(attempts \\ 30)
  defp assert_eventually_empty(0), do: flunk("Periodical did not become empty")

  defp assert_eventually_empty(attempts) do
    case Periodical.stats() do
      %Stats{in_flight: 0, pending: 0, schedules: 0} -> :ok
      _busy -> await_cleanup(attempts)
    end
  end

  # Gives asynchronous cleanup a bounded opportunity to reach the scheduler.
  @spec await_cleanup(pos_integer()) :: :ok
  defp await_cleanup(attempts) do
    receive do
      _message -> assert_eventually_empty(attempts - 1)
    after
      10 -> assert_eventually_empty(attempts - 1)
    end
  end
end
