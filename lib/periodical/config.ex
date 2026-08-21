defmodule Periodical.Config do
  @moduledoc "Loads and validates Periodical's bounded runtime settings."

  alias Periodical.Error

  @mix_env Mix.env()
  @development_build @mix_env == :dev
  @docs_build @mix_env == :docs
  @production_build @mix_env == :prod
  @test_build @mix_env == :test
  @allowed_keys [
    :admission_timeout_ms,
    :clock_module,
    :default_execution_timeout_ms,
    :default_misfire,
    :default_overlap,
    :default_time_zone,
    :health_gate,
    :max_execution_timeout_ms,
    :max_in_flight,
    :max_pending_triggers,
    :max_schedules,
    :shutdown_timeout_ms,
    :timer_module
  ]
  @defaults [
    admission_timeout_ms: :timer.seconds(5),
    clock_module: Periodical.Clock.System,
    default_execution_timeout_ms: :timer.seconds(60),
    default_misfire: :skip,
    default_overlap: :skip,
    default_time_zone: "Etc/UTC",
    health_gate: nil,
    max_execution_timeout_ms: :timer.hours(1),
    max_in_flight: 4,
    max_pending_triggers: 256,
    max_schedules: 1_024,
    shutdown_timeout_ms: :timer.seconds(5),
    timer_module: Periodical.Timer.System
  ]

  @enforce_keys @allowed_keys
  defstruct @allowed_keys

  @typedoc "A policy applied when an occurrence cannot run on time."
  @type misfire_policy :: :fire_once | :skip

  @typedoc "A policy controlling concurrent occurrences of one schedule."
  @type overlap_policy :: :allow | :skip

  @typedoc "Validated immutable Periodical runtime configuration."
  @opaque t :: %__MODULE__{}

  ##
  ## Public API
  ##

  # Public functions

  @doc "Loads and validates the optional `Periodical.Config` application namespace."

  @spec load() :: {:ok, t()} | {:error, Error.t()}
  def load, do: :periodical |> Application.get_env(__MODULE__, []) |> new()

  @doc "Validates an explicit Periodical configuration keyword list."
  @spec new(keyword() | term()) :: {:ok, t()} | {:error, Error.t()}
  def new(settings) when is_list(settings) do
    with :ok <- validate_keys(settings),
         values <- Keyword.merge(@defaults, settings),
         :ok <- validate_values(values),
         :ok <- validate_modules(values),
         :ok <- validate_relationships(values) do
      {:ok, struct!(__MODULE__, values)}
    end
  end

  def new(_settings), do: invalid(:settings, :supported_unique_keyword_list)

  @doc "Returns the admission call timeout in milliseconds."
  @spec admission_timeout_ms(t()) :: pos_integer()
  def admission_timeout_ms(%__MODULE__{admission_timeout_ms: value}), do: value

  @doc "Returns the configured wall-clock implementation."
  @spec clock_module(t()) :: module()
  def clock_module(%__MODULE__{clock_module: value}), do: value

  @doc "Returns the default callback execution timeout in milliseconds."
  @spec default_execution_timeout_ms(t()) :: pos_integer()
  def default_execution_timeout_ms(%__MODULE__{default_execution_timeout_ms: value}), do: value

  @doc "Returns the default missed-occurrence policy."
  @spec default_misfire(t()) :: misfire_policy()
  def default_misfire(%__MODULE__{default_misfire: value}), do: value

  @doc "Returns the default overlap policy."
  @spec default_overlap(t()) :: overlap_policy()
  def default_overlap(%__MODULE__{default_overlap: value}), do: value

  @doc "Returns the default recurrence timezone."
  @spec default_time_zone(t()) :: Calendar.time_zone()
  def default_time_zone(%__MODULE__{default_time_zone: value}), do: value

  @doc "Returns the optional health gate controlling registration and dispatch."
  @spec health_gate(t()) :: atom() | nil
  def health_gate(%__MODULE__{health_gate: value}), do: value

  @doc "Returns the maximum callback execution timeout in milliseconds."
  @spec max_execution_timeout_ms(t()) :: pos_integer()
  def max_execution_timeout_ms(%__MODULE__{max_execution_timeout_ms: value}), do: value

  @doc "Returns the maximum number of concurrently executing callbacks."
  @spec max_in_flight(t()) :: pos_integer()
  def max_in_flight(%__MODULE__{max_in_flight: value}), do: value

  @doc "Returns the maximum number of pending trigger occurrences."
  @spec max_pending_triggers(t()) :: pos_integer()
  def max_pending_triggers(%__MODULE__{max_pending_triggers: value}), do: value

  @doc "Returns the maximum number of registered schedules."
  @spec max_schedules(t()) :: pos_integer()
  def max_schedules(%__MODULE__{max_schedules: value}), do: value

  @doc "Returns the supervisor's bounded shutdown timeout in milliseconds."
  @spec shutdown_timeout_ms(t()) :: pos_integer()
  def shutdown_timeout_ms(%__MODULE__{shutdown_timeout_ms: value}), do: value

  @doc "Returns the configured one-shot timer implementation."
  @spec timer_module(t()) :: module()
  def timer_module(%__MODULE__{timer_module: value}), do: value

  @doc "Returns whether this library was compiled for development."
  @spec development?() :: boolean()
  def development?, do: @development_build

  @doc "Returns whether this library was compiled for documentation."
  @spec docs?() :: boolean()
  def docs?, do: @docs_build

  @doc "Returns the Mix build environment captured at compilation."
  @spec mix_env() :: atom()
  def mix_env, do: @mix_env

  @doc "Returns whether this library was compiled for production."
  @spec production?() :: boolean()
  def production?, do: @production_build

  @doc "Returns whether this library was compiled for tests."
  @spec test?() :: boolean()
  def test?, do: @test_build

  ##
  ## Private Functions
  ##

  # Internal helpers

  # Rejects unknown, duplicate, and non-keyword settings.
  @spec validate_keys(term()) :: :ok | {:error, Error.t()}
  defp validate_keys(settings) do
    keys = if Keyword.keyword?(settings), do: Keyword.keys(settings), else: []

    if Keyword.keyword?(settings) and Enum.uniq(keys) == keys and keys -- @allowed_keys == [],
      do: :ok,
      else: invalid(:settings, :supported_unique_keyword_list)
  end

  # Validates scalar limits and finite policy values.
  @spec validate_values(keyword()) :: :ok | {:error, Error.t()}
  defp validate_values(values) do
    positive = [
      :admission_timeout_ms,
      :default_execution_timeout_ms,
      :max_execution_timeout_ms,
      :max_in_flight,
      :max_pending_triggers,
      :max_schedules,
      :shutdown_timeout_ms
    ]

    cond do
      Enum.any?(positive, &(not positive_integer?(values[&1]))) -> invalid(:settings, :positive_limits)
      values[:default_misfire] not in [:fire_once, :skip] -> invalid(:default_misfire, :supported_policy)
      values[:default_overlap] not in [:allow, :skip] -> invalid(:default_overlap, :supported_policy)
      not valid_time_zone?(values[:default_time_zone]) -> invalid(:default_time_zone, :non_empty_binary)
      not valid_gate?(values[:health_gate]) -> invalid(:health_gate, :atom_or_nil)
      true -> :ok
    end
  end

  # Requires configured clock and timer implementations to satisfy their behaviours.
  @spec validate_modules(keyword()) :: :ok | {:error, Error.t()}
  defp validate_modules(values) do
    clock? = exports?(values[:clock_module], now: 1)
    timer? = exports?(values[:timer_module], send_after: 3, cancel: 1)

    if clock? and timer?, do: :ok, else: invalid(:modules, :clock_and_timer_behaviours)
  end

  # Keeps the default callback timeout inside the configured hard maximum.
  @spec validate_relationships(keyword()) :: :ok | {:error, Error.t()}
  defp validate_relationships(values) do
    if values[:default_execution_timeout_ms] <= values[:max_execution_timeout_ms],
      do: :ok,
      else: invalid(:settings, :consistent_timeout_bounds)
  end

  # Checks a strictly positive integer setting.
  @spec positive_integer?(term()) :: boolean()
  defp positive_integer?(value), do: is_integer(value) and value > 0

  # Checks a bounded timezone identifier without consulting external data.
  @spec valid_time_zone?(term()) :: boolean()
  defp valid_time_zone?(value), do: is_binary(value) and byte_size(value) in 1..128

  # Accepts no health integration or one statically named gate.
  @spec valid_gate?(term()) :: boolean()
  defp valid_gate?(nil), do: true
  defp valid_gate?(gate), do: is_atom(gate) and gate not in [nil, true, false]

  # Checks an adapter's required exported functions.
  @spec exports?(term(), keyword()) :: boolean()
  defp exports?(module, functions) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(functions, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  defp exports?(_module, _functions), do: false

  # Builds a bounded configuration error without echoing supplied settings.
  @spec invalid(atom(), atom()) :: {:error, Error.t()}
  defp invalid(field, expected), do: {:error, Error.invalid_config(%{field: field, expected: expected})}
end
