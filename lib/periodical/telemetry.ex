defmodule Periodical.Telemetry do
  @moduledoc """
  Periodical's canonical, reporter-independent telemetry events.

  Every event is emitted through `:telemetry`, so any reporter can consume them
  without Periodical knowing which. Names follow `[:periodical, subject,
  operation]`.

  ## Events

  | Event | Kind | Measurement | Metadata |
  | --- | --- | --- | --- |
  | `[:periodical, :schedule, :register]` | counter | `:count` | `:result` |
  | `[:periodical, :schedule, :control]` | counter | `:count` | `:operation`, `:result` |
  | `[:periodical, :trigger, :execute, :start\\|:stop\\|:exception]` | span | `:duration` (native) | `:kind`, `:schedule_id`, and `:result` on stop |
  | `[:periodical, :trigger, :terminal]` | counter | `:count` | `:result` |
  | `[:periodical, :trigger, :skipped]` | counter | `:count` | `:reason` |
  | `[:periodical, :trigger, :lateness]` | distribution | `:milliseconds` | — |
  | `[:periodical, :scheduler, :schedules]` | last value | `:value` | — |
  | `[:periodical, :scheduler, :pending]` | last value | `:value` | — |
  | `[:periodical, :scheduler, :in_flight]` | last value | `:value` | — |

  ## Tracing

  Periodical does not depend on a tracing library. The execute event is a
  proper `:telemetry` span, carrying the trigger's kind and schedule identifier
  as metadata, so a host that bridges `:telemetry` spans to its tracer gets a
  span per trigger without Periodical knowing the tracer exists.

  ## Context propagation

  A schedule is registered in one process and its callback runs in another, so
  anything the registering process carried is not automatically present during
  execution. `capture_context/0` and `with_context/2` bridge that gap and are
  pluggable; the default carries `Logger.metadata/0`.

      config :periodical, context: MyApp.TraceContext

  See `Periodical.Telemetry.Context`.
  """

  @app :periodical

  @typedoc "Opaque context captured in one process and restored in another."
  @type context :: term()

  ##
  ## Public API
  ##

  # Counters

  @doc "Records schedule registration attempts by result."
  @spec schedule_register(non_neg_integer(), map()) :: :ok
  def schedule_register(count, metadata \\ %{}), do: count(:schedule, :register, count, metadata)

  @doc "Records schedule control operations."
  @spec schedule_control(non_neg_integer(), map()) :: :ok
  def schedule_control(count, metadata \\ %{}), do: count(:schedule, :control, count, metadata)

  @doc "Records terminal trigger outcomes."
  @spec trigger_terminal(non_neg_integer(), map()) :: :ok
  def trigger_terminal(count, metadata \\ %{}), do: count(:trigger, :terminal, count, metadata)

  @doc "Records triggers that were skipped rather than executed."
  @spec trigger_skipped(non_neg_integer(), map()) :: :ok
  def trigger_skipped(count, metadata \\ %{}), do: count(:trigger, :skipped, count, metadata)

  # Distributions

  @doc "Records how late a trigger fired against its scheduled time."
  @spec trigger_lateness(non_neg_integer()) :: :ok
  def trigger_lateness(milliseconds),
    do: :telemetry.execute([@app, :trigger, :lateness], %{milliseconds: milliseconds}, %{})

  # Last values

  @doc "Reports how many schedules are registered."
  @spec scheduler_schedules(non_neg_integer()) :: :ok
  def scheduler_schedules(value), do: last_value(:scheduler, :schedules, value)

  @doc "Reports how many triggers are waiting to fire."
  @spec scheduler_pending(non_neg_integer()) :: :ok
  def scheduler_pending(value), do: last_value(:scheduler, :pending, value)

  @doc "Reports how many callbacks are currently executing."
  @spec scheduler_in_flight(non_neg_integer()) :: :ok
  def scheduler_in_flight(value), do: last_value(:scheduler, :in_flight, value)

  # Spans

  @doc """
  Measures one trigger execution, emitting `:start`, `:stop` and `:exception`.

  `function` must return `{result, extra_metadata}`: the result is passed back
  to the caller and the extra metadata is merged into the `:stop` event, which
  is how the outcome reaches reporters without the callback's arguments or
  return value going with it.

  An exception is re-raised with its original stacktrace after the
  `:exception` event is emitted.
  """
  @spec trigger_execute(map(), (-> {result, map()})) :: result when result: term()
  def trigger_execute(metadata \\ %{}, function) when is_function(function, 0),
    do: :telemetry.span([@app, :trigger, :execute], metadata, function)

  # Context propagation

  @doc "Captures the current process's context for later restoration."
  @spec capture_context() :: context()
  def capture_context, do: context_module().capture()

  @doc "Runs `function` with a previously captured context applied."
  @spec with_context(context(), (-> result)) :: result when result: term()
  def with_context(context, function) when is_function(function, 0),
    do: context_module().with(context, function)

  ##
  ## Private Functions
  ##

  # Emission

  # Emits one counter event under this library's own namespace.
  @spec count(atom(), atom(), non_neg_integer(), map()) :: :ok
  defp count(subject, operation, value, metadata),
    do: :telemetry.execute([@app, subject, operation], %{count: value}, metadata)

  # Emits one last-value event under this library's own namespace.
  @spec last_value(atom(), atom(), non_neg_integer()) :: :ok
  defp last_value(subject, operation, value),
    do: :telemetry.execute([@app, subject, operation], %{value: value}, %{})

  # Resolves the configured context implementation, defaulting to Logger metadata.
  @spec context_module() :: module()
  defp context_module,
    do: Application.get_env(@app, :context, Periodical.Telemetry.LoggerContext)
end
