defmodule Periodical do
  @moduledoc """
  Runs bounded local recurring and one-time schedules.

  Schedule state is in memory and local to one BEAM instance. Periodical does
  not provide durable triggering, cluster-wide singleton execution, or retries.
  A callback that requires durable execution should explicitly publish to a
  durable queue at its application-owned boundary.
  """

  alias Periodical.Recurrence
  alias Periodical.{Config, Error, Schedule, Scheduler, Stats}

  @typedoc "A schedule identifier local to one scheduler-process lifetime."
  @type schedule_id :: pos_integer()

  @typedoc "A unique optional schedule name."
  @type schedule_name :: atom() | tuple()

  @typedoc "A schedule identifier or unique name."
  @type schedule_reference :: schedule_id() | schedule_name()

  ##
  ## Public API
  ##

  # Public functions

  @doc "Registers a recurring MFA callback from a recurrence struct or expression."

  @spec every(Recurrence.t() | String.t(), module(), atom(), list(), keyword()) ::
          {:ok, schedule_id()} | {:error, Error.t()}
  def every(recurrence, module, function, args \\ [], options \\ []) do
    with {:ok, schedule} <- Schedule.recurring(recurrence) do
      register(schedule, module, function, args, options)
    end
  end

  @doc "Registers a one-time MFA callback at an explicit future DateTime."
  @spec once(DateTime.t(), module(), atom(), list(), keyword()) ::
          {:ok, schedule_id()} | {:error, Error.t()}
  def once(datetime, module, function, args \\ [], options \\ []) do
    with {:ok, reference} <- now(options),
         {:ok, schedule} <- Schedule.once(datetime, reference) do
      register(schedule, module, function, args, options)
    end
  end

  @doc "Cancels a schedule and any pending or running local occurrences."
  @spec cancel(schedule_reference()) :: :ok | {:error, Error.t()}
  def cancel(reference), do: call({:cancel, reference})

  @doc "Pauses future and pending occurrences without terminating an active callback."
  @spec pause(schedule_reference()) :: :ok | {:error, Error.t()}
  def pause(reference), do: call({:pause, reference})

  @doc "Resumes a paused schedule from the current explicit clock instant."
  @spec resume(schedule_reference()) :: :ok | {:error, Error.t()}
  def resume(reference), do: call({:resume, reference})

  @doc "Returns bounded count-only scheduler utilization."
  @spec stats() :: Stats.t()
  def stats, do: call(:stats)

  @doc """
  Stops new registration and waits up to `timeout_ms` for active callbacks.

  Pending occurrences and registered schedules are not dispatched after drain
  begins. Periodical keeps them only in memory, so they are discarded when the
  owning application subsequently stops.
  """
  @spec drain(pos_integer()) :: :ok | {:error, Error.t()}
  def drain(timeout_ms \\ shutdown_timeout_ms()) when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(Scheduler, {:drain, timeout_ms}, :infinity)
  end

  ##
  ## Private Functions
  ##

  # Internal helpers

  # Registers one normalized schedule through the bounded scheduler call boundary.
  @spec register(Schedule.t(), module(), atom(), list(), keyword()) ::
          {:ok, schedule_id()} | {:error, Error.t()}
  defp register(schedule, module, function, args, options) do
    call({:register, schedule, module, function, args, options})
  end

  # Reads current time only to validate a one-time public boundary before registration.
  @spec now(keyword()) :: {:ok, DateTime.t()} | {:error, Error.t()}
  defp now(options) do
    with {:ok, config} <- Config.load(),
         time_zone <- Keyword.get(options, :time_zone, Config.default_time_zone(config)),
         {:ok, now} <- Config.clock_module(config).now(time_zone) do
      {:ok, now}
    else
      _error -> {:error, Error.invalid_schedule(%{field: :time_zone})}
    end
  end

  # Uses the validated configured admission timeout for every public runtime call.
  @spec call(term()) :: term()
  defp call(message) do
    case Config.load() do
      {:ok, config} -> GenServer.call(Scheduler, message, Config.admission_timeout_ms(config))
      {:error, error} -> {:error, error}
    end
  end

  # Reads the locally owned shutdown timeout through the validated Config boundary.
  @spec shutdown_timeout_ms() :: pos_integer()
  defp shutdown_timeout_ms do
    case Config.load() do
      {:ok, config} -> Config.shutdown_timeout_ms(config)
      {:error, error} -> raise error
    end
  end
end
