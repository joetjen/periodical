defmodule Periodical.Scheduler do
  @moduledoc false

  use GenServer

  alias Periodical.Scheduler.Tree, as: GBTree
  alias Periodical.{Config, Error, Job, Schedule, Stats, Telemetry, Trigger}

  @type state :: map()
  @type pending_key :: {integer(), pos_integer()}
  @type run :: %{job_id: pos_integer(), task: Task.t(), timeout_ref: term(), token: reference()}

  ##
  ## Public API
  ##

  # Public functions

  @doc "Starts the single local scheduler with validated immutable configuration."

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  ##
  ## Callback Implementations
  ##

  # Behaviour callbacks

  @impl true
  @spec init(Config.t()) :: {:ok, state()} | {:stop, Error.t()}
  def init(config) do
    with {:ok, gate_open?} <- subscribe_gate(Config.health_gate(config)) do
      {:ok, initial_state(config, gate_open?)}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) ::
          {:reply, term(), state()} | {:noreply, state()}
  def handle_call({:register, schedule, module, function, args, options}, _from, state) do
    case register(state, schedule, module, function, args, options) do
      {:ok, id, next_state} -> {:reply, {:ok, id}, emit_utilization(next_state)}
      {:error, error, next_state} -> {:reply, {:error, error}, next_state}
    end
  end

  def handle_call({operation, reference}, _from, state) when operation in [:cancel, :pause, :resume] do
    case control(state, operation, reference) do
      {:ok, next_state} -> {:reply, :ok, next_state |> emit_utilization() |> finish_drain_waiters()}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(:stats, _from, state), do: {:reply, stats(state), state}

  def handle_call({:drain, timeout_ms}, from, state) do
    state = %{state | draining?: true, gate_open?: false}

    if map_size(state.running) == 0 do
      {:reply, :ok, state}
    else
      {:noreply, add_drain_waiter(state, from, timeout_ms)}
    end
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()} | {:stop, Error.t(), state()}
  def handle_info({:occurrence_due, id, token, scheduled_at}, state) do
    case due(state, id, token, scheduled_at) do
      {:ok, next_state} -> {:noreply, next_state |> dispatch() |> emit_utilization()}
      {:error, error} -> {:stop, error, state}
    end
  end

  def handle_info({:execution_timeout, reference, token}, state) do
    case Map.get(state.running, reference) do
      %{token: ^token} = run -> {:noreply, finish_run(state, reference, run, :timeout)}
      _missing_or_stale -> {:noreply, state}
    end
  end

  def handle_info({reference, _result}, state) when is_reference(reference) do
    case Map.get(state.running, reference) do
      nil -> {:noreply, state}
      run -> {:noreply, finish_run(state, reference, run, :ok)}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, state) do
    case Map.get(state.running, reference) do
      nil -> {:noreply, state}
      run -> {:noreply, finish_run(state, reference, run, :error)}
    end
  end

  def handle_info({:drain_timeout, token}, state) do
    {:noreply, expire_drain_waiter(state, token)}
  end

  def handle_info({tag, gate, :open}, %{gate: gate, gate_tag: tag, draining?: true} = state),
    do: {:noreply, state}

  def handle_info({tag, gate, :open}, %{gate: gate, gate_tag: tag} = state) do
    next_state = %{state | gate_open?: true} |> dispatch() |> emit_utilization()
    {:noreply, next_state}
  end

  def handle_info({tag, gate, :closed, _reason}, %{gate: gate, gate_tag: tag} = state) do
    {:noreply, %{state | gate_open?: false}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, state) do
    unsubscribe_gate(state.gate)
    Enum.each(state.jobs, fn {_id, job} -> cancel_timer(state, job.timer_ref) end)
    Enum.each(state.running, fn {_reference, run} -> stop_task(state, run) end)
  end

  ##
  ## Private Functions
  ##

  # Internal helpers

  # Constructs the complete bounded scheduler state.
  @spec initial_state(Config.t(), boolean()) :: state()
  defp initial_state(config, gate_open?) do
    %{
      active_counts: %{},
      config: config,
      drain_waiters: %{},
      draining?: false,
      gate: Config.health_gate(config),
      gate_tag: Periodical.Gate.message_tag(),
      gate_open?: gate_open?,
      jobs: %{},
      names: %{},
      next_id: 1,
      pending: GBTree.new(),
      pending_counts: %{},
      running: %{}
    }
  end

  # Registers, validates, and arms one schedule without partial state changes.
  @spec register(state(), Schedule.t(), module(), atom(), list(), keyword()) ::
          {:ok, pos_integer(), state()} | {:error, term(), state()}
  defp register(state, schedule, module, function, args, options) do
    id = state.next_id

    with :ok <- ensure_registration_open(state),
         :ok <- ensure_schedule_capacity(state),
         {:ok, now} <- clock_now(state, option_time_zone(state, options)),
         {:ok, job} <- Job.new(id, schedule, module, function, args, options, state.config, now),
         :ok <- ensure_unique_name(state, job.name),
         {:ok, armed_job} <- arm_job(state, job, now) do
      next_state = put_job(%{state | next_id: id + 1}, armed_job)
      emit_registration(:accepted)
      {:ok, id, next_state}
    else
      {:error, error} -> reject_registration(state, error)
    end
  end

  # Classifies a rejected registration into one bounded telemetry value.
  @spec reject_registration(state(), term()) :: {:error, term(), state()}
  defp reject_registration(state, %Error{code: :duplicate_name} = error) do
    emit_registration(:duplicate)
    {:error, error, state}
  end

  defp reject_registration(state, %Error{code: :overloaded} = error) do
    emit_registration(:overloaded)
    {:error, error, state}
  end

  defp reject_registration(state, %Error{code: :shutting_down} = error) do
    emit_registration(:shutting_down)
    {:error, error, state}
  end

  defp reject_registration(state, error) do
    emit_registration(:invalid)
    {:error, error, state}
  end

  # Applies one idempotent schedule-control operation.
  @spec control(state(), :cancel | :pause | :resume, Periodical.schedule_reference()) ::
          {:ok, state()} | {:error, Error.t()}
  defp control(state, operation, reference) do
    with {:ok, id} <- resolve_reference(state, reference),
         {:ok, next_state} <- apply_control(state, operation, id) do
      emit_control(operation, :ok)
      {:ok, next_state}
    else
      {:error, error} ->
        emit_control(operation, :error)
        {:error, error}
    end
  end

  # Cancels all timer, pending, and callback ownership for one schedule.
  @spec apply_control(state(), :cancel, pos_integer()) :: {:ok, state()}
  defp apply_control(state, :cancel, id) do
    job = Map.fetch!(state.jobs, id)
    cancel_timer(state, job.timer_ref)

    next_state = state |> remove_pending(id, :cancelled) |> stop_runs(id) |> delete_job(id)
    {:ok, next_state}
  end

  # Pauses future and queued work while allowing an active callback to finish.
  @spec apply_control(state(), :pause, pos_integer()) :: {:ok, state()}
  defp apply_control(state, :pause, id) do
    job = Map.fetch!(state.jobs, id)
    cancel_timer(state, job.timer_ref)

    paused_job = %{job | status: :paused, timer_ref: nil, timer_token: nil}
    {:ok, state |> put_job(paused_job) |> remove_pending(id, :paused)}
  end

  # Resumes an inactive schedule according to its missed-occurrence policy.
  @spec apply_control(state(), :resume, pos_integer()) :: {:ok, state()} | {:error, Error.t()}
  defp apply_control(state, :resume, id) do
    job = Map.fetch!(state.jobs, id)

    if job.status == :active do
      {:ok, state}
    else
      resume_job(state, job)
    end
  end

  # Calculates and arms the next occurrence for one paused job.
  @spec resume_job(state(), Job.t()) :: {:ok, state()} | {:error, Error.t()}
  defp resume_job(state, job) do
    with {:ok, now} <- clock_now(state, job.time_zone) do
      case Schedule.next(job.schedule, now) do
        {:ok, next_at} -> arm_resumed_job(state, %{job | status: :active, next_at: next_at}, now)
        {:error, _error} -> resume_missed_once(state, %{job | status: :active}, now)
      end
    end
  end

  # Arms a resumed future occurrence and stores it.
  @spec arm_resumed_job(state(), Job.t(), DateTime.t()) :: {:ok, state()} | {:error, Error.t()}
  defp arm_resumed_job(state, job, now) do
    case arm_job(state, job, now) do
      {:ok, armed_job} -> {:ok, put_job(state, armed_job)}
      {:error, _error} -> {:error, Error.invalid_schedule(%{reason: :timer_unavailable})}
    end
  end

  # Resolves a missed one-time schedule without manufacturing catch-up loops.
  @spec resume_missed_once(state(), Job.t(), DateTime.t()) :: {:ok, state()}
  defp resume_missed_once(state, %{schedule: %{kind: :once}, misfire: :fire_once} = job, now) do
    trigger = trigger(job, job.schedule.value, now)
    {:ok, state |> put_job(job) |> enqueue(job, trigger) |> dispatch()}
  end

  defp resume_missed_once(state, job, _now), do: {:ok, delete_job(state, job.id)}

  # Handles one current timer token and rejects stale timer messages silently.
  @spec due(state(), pos_integer(), reference(), DateTime.t()) :: {:ok, state()} | {:error, Error.t()}
  defp due(state, id, token, scheduled_at) do
    case Map.get(state.jobs, id) do
      %Job{status: :active, timer_token: ^token} = job -> process_due(state, job, scheduled_at)
      _stale -> {:ok, state}
    end
  end

  # Creates one trigger, applies admission policy, and advances its schedule.
  @spec process_due(state(), Job.t(), DateTime.t()) :: {:ok, state()} | {:error, Error.t()}
  defp process_due(state, job, scheduled_at) do
    with {:ok, now} <- clock_now(state, job.time_zone),
         next_state <- clear_job_timer(state, job),
         admitted_state <- admit_occurrence(next_state, job, trigger(job, scheduled_at, now)),
         {:ok, advanced_state} <- advance_job(admitted_state, job, scheduled_at, now) do
      {:ok, advanced_state}
    end
  end

  # Admits, coalesces, or skips one due occurrence under bounded policy.
  @spec admit_occurrence(state(), Job.t(), Trigger.t()) :: state()
  defp admit_occurrence(state, job, trigger) do
    reason = rejection_reason(state, job)

    cond do
      reason == nil -> enqueue(state, job, trigger)
      job.misfire == :fire_once and can_coalesce?(state, job) -> enqueue(state, job, trigger)
      true -> skip_trigger(state, job, reason)
    end
  end

  # Identifies the first finite reason an occurrence cannot be admitted now.
  @spec rejection_reason(state(), Job.t()) :: atom() | nil
  defp rejection_reason(state, job) do
    cond do
      not state.gate_open? -> :gate_closed
      job.overlap == :skip and occupied?(state, job.id) -> :overlap
      GBTree.size(state.pending) >= Config.max_pending_triggers(state.config) -> :pending_capacity
      true -> nil
    end
  end

  # Allows fire-once policy to retain at most one queued occurrence per job.
  @spec can_coalesce?(state(), Job.t()) :: boolean()
  defp can_coalesce?(state, job) do
    Map.get(state.pending_counts, job.id, 0) == 0 and
      GBTree.size(state.pending) < Config.max_pending_triggers(state.config)
  end

  # Advances recurring cadence or retires a skipped one-time schedule.
  @spec advance_job(state(), Job.t(), DateTime.t(), DateTime.t()) :: {:ok, state()} | {:error, Error.t()}
  defp advance_job(state, %{schedule: %{kind: :once}} = job, _scheduled_at, _now) do
    if occupied?(state, job.id), do: {:ok, state}, else: {:ok, delete_job(state, job.id)}
  end

  defp advance_job(state, job, scheduled_at, now) do
    with {:ok, next_at} <- Schedule.following(job.schedule, scheduled_at, now),
         {:ok, armed_job} <- arm_job(state, %{job | next_at: next_at}, now) do
      {:ok, put_job(state, armed_job)}
    else
      _error -> {:error, Error.invalid_schedule(%{reason: :next_occurrence_unavailable})}
    end
  end

  # Adds one occurrence to the stable scheduled-time and registration-order queue.
  @spec enqueue(state(), Job.t(), Trigger.t()) :: state()
  defp enqueue(state, job, trigger) do
    key = {DateTime.to_unix(trigger.scheduled_at, :microsecond), job.sequence}
    pending = GBTree.put(state.pending, key, {job.id, trigger})
    counts = Map.update(state.pending_counts, job.id, 1, &(&1 + 1))

    Telemetry.trigger_lateness(trigger.lateness_ms)
    %{state | pending: pending, pending_counts: counts}
  end

  # Dispatches queued work until the gate or configured concurrency bound closes.
  @spec dispatch(state()) :: state()
  defp dispatch(state) do
    if dispatchable?(state) do
      case take_pending(state) do
        :empty -> state
        {:ok, job, trigger, next_state} -> next_state |> start_or_skip(job, trigger) |> dispatch()
      end
    else
      state
    end
  end

  # Checks the two global callback admission bounds.
  @spec dispatchable?(state()) :: boolean()
  defp dispatchable?(state) do
    state.gate_open? and map_size(state.running) < Config.max_in_flight(state.config)
  end

  # Removes the oldest pending trigger and resolves its still-live job.
  @spec take_pending(state()) :: :empty | {:ok, Job.t(), Trigger.t(), state()}
  defp take_pending(state) do
    case GBTree.smallest(state.pending) do
      :empty -> :empty
      {:ok, {key, {id, trigger}}} -> resolve_pending(state, key, id, trigger)
    end
  end

  # Discards stale queue entries and continues until a live one is found.
  @spec resolve_pending(state(), pending_key(), pos_integer(), Trigger.t()) ::
          :empty | {:ok, Job.t(), Trigger.t(), state()}
  defp resolve_pending(state, key, id, trigger) do
    next_state = drop_pending_key(state, key, id)

    case Map.get(next_state.jobs, id) do
      %Job{status: :active} = job -> {:ok, job, trigger, next_state}
      _stale -> take_pending(next_state)
    end
  end

  # Starts a callback unless its per-job non-overlap contract became occupied.
  @spec start_or_skip(state(), Job.t(), Trigger.t()) :: state()
  defp start_or_skip(state, %{overlap: :skip} = job, trigger) do
    if Map.get(state.active_counts, job.id, 0) > 0,
      do: skip_trigger(state, job, :overlap),
      else: start_run(state, job, trigger)
  end

  defp start_or_skip(state, job, trigger), do: start_run(state, job, trigger)

  # Starts one monitored callback and its independent execution deadline.
  @spec start_run(state(), Job.t(), Trigger.t()) :: state()
  defp start_run(state, job, trigger) do
    task = Task.Supervisor.async_nolink(Periodical.TaskSupervisor, fn -> execute(job, trigger) end)
    token = make_ref()

    case Config.timer_module(state.config).send_after(
           job.execution_timeout_ms,
           self(),
           {:execution_timeout, task.ref, token}
         ) do
      {:ok, timeout_ref} ->
        put_run(state, task, job, timeout_ref, token)

      {:error, _error} ->
        Task.shutdown(task, :brutal_kill)
        terminal_job(state, job.id, :error)
    end
  end

  # Executes the callback as a new trace entry and canonical telemetry span.
  @spec execute(Job.t(), Trigger.t()) :: term()
  defp execute(job, trigger) do
    # The telemetry span is the trace boundary. A host that bridges `:telemetry`
    # spans to its tracer gets a span per trigger, carrying the same attributes
    # a dedicated tracing call used to set, without Periodical depending on any
    # particular tracing library.
    metadata = %{kind: trigger.kind, schedule_id: trigger.schedule_id}

    Telemetry.trigger_execute(metadata, fn ->
      {apply(job.module, job.function, [trigger | job.args]), %{result: :ok}}
    end)
  end

  # Stores active callback ownership and increments its per-job count.
  @spec put_run(state(), Task.t(), Job.t(), term(), reference()) :: state()
  defp put_run(state, task, job, timeout_ref, token) do
    run = %{job_id: job.id, task: task, timeout_ref: timeout_ref, token: token}
    running = Map.put(state.running, task.ref, run)
    counts = Map.update(state.active_counts, job.id, 1, &(&1 + 1))
    %{state | active_counts: counts, running: running}
  end

  # Completes callback ownership exactly once and resumes bounded dispatch.
  @spec finish_run(state(), reference(), run(), atom()) :: state()
  defp finish_run(state, reference, run, result) do
    cancel_timer(state, run.timeout_ref)
    Process.demonitor(reference, [:flush])
    if result == :timeout, do: Task.shutdown(run.task, :brutal_kill)

    state
    |> drop_run(reference, run.job_id)
    |> terminal_job(run.job_id, result)
    |> dispatch()
    |> emit_utilization()
    |> finish_drain_waiters()
  end

  # Registers a caller that must be answered when active callbacks end or its deadline expires.
  @spec add_drain_waiter(state(), GenServer.from(), pos_integer()) :: state()
  defp add_drain_waiter(state, from, timeout_ms) do
    token = make_ref()
    {:ok, timer_ref} = Config.timer_module(state.config).send_after(timeout_ms, self(), {:drain_timeout, token})
    put_in(state.drain_waiters[token], {from, timer_ref})
  end

  # Replies to one caller whose bounded drain deadline elapsed.
  @spec expire_drain_waiter(state(), reference()) :: state()
  defp expire_drain_waiter(state, token) do
    case Map.pop(state.drain_waiters, token) do
      {nil, _waiters} ->
        state

      {{from, _timer_ref}, waiters} ->
        GenServer.reply(from, {:error, Error.drain_timeout(%{scope: :running_callbacks})})
        %{state | drain_waiters: waiters}
    end
  end

  # Completes every pending drain call once no callback remains active.
  @spec finish_drain_waiters(state()) :: state()
  defp finish_drain_waiters(%{running: running} = state) when map_size(running) > 0, do: state

  defp finish_drain_waiters(state) do
    Enum.each(state.drain_waiters, fn {_token, {from, timer_ref}} ->
      cancel_timer(state, timer_ref)
      GenServer.reply(from, :ok)
    end)

    %{state | drain_waiters: %{}}
  end

  # Emits one terminal result and retires a completed one-time job.
  @spec terminal_job(state(), pos_integer(), atom()) :: state()
  defp terminal_job(state, job_id, result) do
    Telemetry.trigger_terminal(1, %{result: result})

    case Map.get(state.jobs, job_id) do
      %Job{schedule: %{kind: :once}} -> delete_job(state, job_id)
      _recurring_or_cancelled -> state
    end
  end

  # Removes one running reference and decrements its per-job active count.
  @spec drop_run(state(), reference(), pos_integer()) :: state()
  defp drop_run(state, reference, job_id) do
    %{state | running: Map.delete(state.running, reference), active_counts: decrement(state.active_counts, job_id)}
  end

  # Stops every active callback belonging to a cancelled schedule.
  @spec stop_runs(state(), pos_integer()) :: state()
  defp stop_runs(state, job_id) do
    state.running
    |> Enum.filter(fn {_reference, run} -> run.job_id == job_id end)
    |> Enum.reduce(state, fn {reference, run}, accumulator ->
      stop_task(accumulator, run)
      Telemetry.trigger_terminal(1, %{result: :cancelled})
      drop_run(accumulator, reference, job_id)
    end)
  end

  # Cancels one callback deadline and forcefully terminates its task.
  @spec stop_task(state(), run()) :: :ok
  defp stop_task(state, run) do
    cancel_timer(state, run.timeout_ref)
    Process.demonitor(run.task.ref, [:flush])
    Task.shutdown(run.task, :brutal_kill)
    :ok
  end

  # Arms a job with a token that makes stale timer messages harmless.
  @spec arm_job(state(), Job.t(), DateTime.t()) :: {:ok, Job.t()} | {:error, term()}
  defp arm_job(state, job, now) do
    token = make_ref()
    message = {:occurrence_due, job.id, token, job.next_at}
    delay_ms = Schedule.delay_ms(job.next_at, now)

    case Config.timer_module(state.config).send_after(delay_ms, self(), message) do
      {:ok, timer_ref} -> {:ok, %{job | timer_ref: timer_ref, timer_token: token}}
      {:error, error} -> {:error, error}
    end
  end

  # Clears a fired timer while retaining the schedule registration.
  @spec clear_job_timer(state(), Job.t()) :: state()
  defp clear_job_timer(state, job) do
    put_job(state, %{job | timer_ref: nil, timer_token: nil})
  end

  # Removes all pending entries for a schedule and emits their final disposition.
  @spec remove_pending(state(), pos_integer(), :cancelled | :paused) :: state()
  defp remove_pending(state, id, reason) do
    {removed, kept} = Enum.split_with(GBTree.to_list(state.pending), fn {_key, {job_id, _trigger}} -> job_id == id end)
    Enum.each(removed, fn _entry -> emit_removed_pending(reason) end)
    %{state | pending: GBTree.from_list(kept), pending_counts: Map.delete(state.pending_counts, id)}
  end

  # Classifies cancelled pending work as terminal and paused work as skipped.
  @spec emit_removed_pending(:cancelled | :paused) :: :ok
  defp emit_removed_pending(:cancelled), do: Telemetry.trigger_terminal(1, %{result: :cancelled})
  defp emit_removed_pending(:paused), do: Telemetry.trigger_skipped(1, %{reason: :paused})

  # Drops one known pending queue key and updates per-job occupancy.
  @spec drop_pending_key(state(), pending_key(), pos_integer()) :: state()
  defp drop_pending_key(state, key, id) do
    %{state | pending: GBTree.delete(state.pending, key), pending_counts: decrement(state.pending_counts, id)}
  end

  # Emits a skipped occurrence and retires it when it was one-time work.
  @spec skip_trigger(state(), Job.t(), atom()) :: state()
  defp skip_trigger(state, job, reason) do
    Telemetry.trigger_skipped(1, %{reason: reason})
    if job.schedule.kind == :once, do: delete_job(state, job.id), else: state
  end

  # Stores a job and its optional unique-name lookup.
  @spec put_job(state(), Job.t()) :: state()
  defp put_job(state, job) do
    names = if job.name == nil, do: state.names, else: Map.put(state.names, job.name, job.id)
    %{state | jobs: Map.put(state.jobs, job.id, job), names: names}
  end

  # Removes a job and only the name lookup that still points to it.
  @spec delete_job(state(), pos_integer()) :: state()
  defp delete_job(state, id) do
    case Map.pop(state.jobs, id) do
      {nil, _jobs} -> state
      {job, jobs} -> %{state | jobs: jobs, names: delete_name(state.names, job.name, id)}
    end
  end

  # Deletes one exact optional name mapping.
  @spec delete_name(map(), Job.name(), pos_integer()) :: map()
  defp delete_name(names, nil, _id), do: names
  defp delete_name(names, name, id), do: if(Map.get(names, name) == id, do: Map.delete(names, name), else: names)

  # Resolves either a numeric ID or a bounded unique name.
  @spec resolve_reference(state(), Periodical.schedule_reference()) :: {:ok, pos_integer()} | {:error, Error.t()}
  defp resolve_reference(state, reference) when is_integer(reference) and reference > 0 do
    if Map.has_key?(state.jobs, reference), do: {:ok, reference}, else: schedule_not_found()
  end

  defp resolve_reference(state, reference) do
    case Map.fetch(state.names, reference) do
      {:ok, id} -> {:ok, id}
      :error -> schedule_not_found()
    end
  end

  # Rejects registrations once the configured bounded schedule count is reached.
  @spec ensure_schedule_capacity(state()) :: :ok | {:error, Error.t()}
  defp ensure_schedule_capacity(state) do
    if map_size(state.jobs) < Config.max_schedules(state.config), do: :ok, else: {:error, Error.overloaded()}
  end

  # Rejects new schedules only after explicit shutdown drain has begun.
  @spec ensure_registration_open(state()) :: :ok | {:error, Error.t()}
  defp ensure_registration_open(%{draining?: false}), do: :ok
  defp ensure_registration_open(%{draining?: true}), do: {:error, Error.shutting_down()}

  # Rejects reuse of a live optional schedule name.
  @spec ensure_unique_name(state(), Job.name()) :: :ok | {:error, Error.t()}
  defp ensure_unique_name(_state, nil), do: :ok

  defp ensure_unique_name(state, name),
    do: if(Map.has_key?(state.names, name), do: {:error, Error.duplicate_name()}, else: :ok)

  # Reads current time through the configured deterministic clock boundary.
  @spec clock_now(state(), String.t()) :: {:ok, DateTime.t()} | {:error, Error.t()}
  defp clock_now(state, time_zone) do
    case Config.clock_module(state.config).now(time_zone) do
      {:ok, %DateTime{} = now} -> {:ok, now}
      _error -> {:error, Error.invalid_schedule(%{field: :time_zone})}
    end
  end

  # Reads a registration timezone without accepting malformed option containers.
  @spec option_time_zone(state(), term()) :: String.t()
  defp option_time_zone(state, options) when is_list(options) do
    Keyword.get(options, :time_zone, Config.default_time_zone(state.config))
  end

  defp option_time_zone(state, _options), do: Config.default_time_zone(state.config)

  # Builds the typed callback occurrence payload.
  @spec trigger(Job.t(), DateTime.t(), DateTime.t()) :: Trigger.t()
  defp trigger(job, scheduled_at, now) do
    %Trigger{
      kind: job.schedule.kind,
      lateness_ms: max(DateTime.diff(now, scheduled_at, :millisecond), 0),
      schedule_id: job.id,
      scheduled_at: scheduled_at,
      triggered_at: now
    }
  end

  # Reports whether a schedule already owns pending or active work.
  @spec occupied?(state(), pos_integer()) :: boolean()
  defp occupied?(state, id) do
    Map.get(state.pending_counts, id, 0) > 0 or Map.get(state.active_counts, id, 0) > 0
  end

  # Decrements a positive map counter and removes zero entries.
  @spec decrement(map(), term()) :: map()
  defp decrement(counts, key) do
    case Map.get(counts, key, 0) do
      value when value > 1 -> Map.put(counts, key, value - 1)
      _zero_or_one -> Map.delete(counts, key)
    end
  end

  # Cancels a best-effort timer without allowing a stale result to affect state.
  @spec cancel_timer(state(), term()) :: :ok
  defp cancel_timer(_state, nil), do: :ok

  defp cancel_timer(state, timer_ref) do
    _result = Config.timer_module(state.config).cancel(timer_ref)
    :ok
  end

  # Creates a count-only public state snapshot.
  @spec stats(state()) :: Stats.t()
  defp stats(state) do
    %Stats{
      in_flight: map_size(state.running),
      paused: Enum.count(state.jobs, fn {_id, job} -> job.status == :paused end),
      pending: GBTree.size(state.pending),
      schedule_capacity: Config.max_schedules(state.config),
      schedules: map_size(state.jobs)
    }
  end

  # Emits all current utilization gauges after a state transition.
  @spec emit_utilization(state()) :: state()
  defp emit_utilization(state) do
    Telemetry.scheduler_schedules(map_size(state.jobs))
    Telemetry.scheduler_pending(GBTree.size(state.pending))
    Telemetry.scheduler_in_flight(map_size(state.running))
    state
  end

  # Emits one finite registration outcome.
  @spec emit_registration(atom()) :: :ok
  defp emit_registration(result) do
    _telemetry_result = Telemetry.schedule_register(1, %{result: result})
    :ok
  end

  # Emits one finite control outcome.
  @spec emit_control(atom(), atom()) :: :ok
  defp emit_control(operation, result) do
    _telemetry_result = Telemetry.schedule_control(1, %{operation: operation, result: result})
    :ok
  end

  # Subscribes to the configured optional health gate through its public API.
  @spec subscribe_gate(nil | atom()) :: {:ok, boolean()} | {:error, Error.t()}
  defp subscribe_gate(nil), do: {:ok, true}

  defp subscribe_gate(gate) do
    module = Periodical.Gate.implementation()

    if module != nil and Code.ensure_loaded?(module) and
         function_exported?(module, :subscribe, 1) do
      case apply(module, :subscribe, [gate]) do
        {:ok, :open} -> {:ok, true}
        {:ok, :closed} -> {:ok, false}
        {:error, _error} -> {:error, Error.dependency_unavailable(%{dependency: :gate})}
      end
    else
      {:error, Error.dependency_unavailable(%{dependency: :gate})}
    end
  end

  # Unsubscribes from a configured optional health gate during orderly shutdown.
  @spec unsubscribe_gate(nil | atom()) :: :ok
  defp unsubscribe_gate(nil), do: :ok

  defp unsubscribe_gate(gate) do
    module = Periodical.Gate.implementation()

    if module != nil and Code.ensure_loaded?(module),
      do: apply(module, :unsubscribe, [gate])

    :ok
  end

  # Returns a stable missing-schedule error without echoing the supplied reference.
  @spec schedule_not_found() :: {:error, Error.t()}
  defp schedule_not_found, do: {:error, Error.schedule_not_found()}
end
