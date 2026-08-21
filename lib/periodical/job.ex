defmodule Periodical.Job do
  @moduledoc false

  alias Periodical.{Config, Error, Schedule}

  @allowed_options [:execution_timeout_ms, :misfire, :name, :overlap, :time_zone]
  @enforce_keys [
    :args,
    :execution_timeout_ms,
    :function,
    :id,
    :misfire,
    :module,
    :name,
    :next_at,
    :overlap,
    :schedule,
    :sequence,
    :status,
    :time_zone
  ]
  defstruct @enforce_keys ++ [timer_ref: nil, timer_token: nil]

  @type name :: atom() | tuple() | nil
  @type status :: :active | :paused
  @type t :: %__MODULE__{
          args: list(),
          execution_timeout_ms: pos_integer(),
          function: atom(),
          id: pos_integer(),
          misfire: Config.misfire_policy(),
          module: module(),
          name: name(),
          next_at: DateTime.t(),
          overlap: Config.overlap_policy(),
          schedule: Schedule.t(),
          sequence: pos_integer(),
          status: status(),
          time_zone: Calendar.time_zone(),
          timer_ref: term(),
          timer_token: reference() | nil
        }

  ##
  ## Public API
  ##

  # Public functions

  @doc "Validates callback metadata and constructs an internal scheduled job."
  @spec new(pos_integer(), Schedule.t(), module(), atom(), list(), keyword(), Config.t(), DateTime.t()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(id, schedule, module, function, args, options, config, reference) do
    with :ok <- validate_options(options),
         :ok <- validate_mfa(module, function, args),
         {:ok, name} <- validate_name(Keyword.get(options, :name)),
         {:ok, overlap} <- validate_overlap(Keyword.get(options, :overlap, Config.default_overlap(config))),
         {:ok, misfire} <- validate_misfire(Keyword.get(options, :misfire, Config.default_misfire(config))),
         {:ok, timeout_ms} <- validate_timeout(options, config),
         {:ok, time_zone} <- validate_time_zone(Keyword.get(options, :time_zone, Config.default_time_zone(config))),
         {:ok, next_at} <- Schedule.next(schedule, reference) do
      {:ok,
       build(
         id,
         schedule,
         {module, function, args},
         options_map(name, overlap, misfire, timeout_ms, time_zone),
         next_at
       )}
    end
  end

  ##
  ## Private Functions
  ##

  # Internal helpers

  # Constructs a validated schedule registration.
  @spec build(pos_integer(), Schedule.t(), {module(), atom(), list()}, map(), DateTime.t()) :: t()
  defp build(id, schedule, {module, function, args}, values, next_at) do
    %__MODULE__{
      args: args,
      execution_timeout_ms: values.timeout_ms,
      function: function,
      id: id,
      misfire: values.misfire,
      module: module,
      name: values.name,
      next_at: next_at,
      overlap: values.overlap,
      schedule: schedule,
      sequence: id,
      status: :active,
      time_zone: values.time_zone
    }
  end

  # Groups validated scalar options without exposing raw input.
  @spec options_map(name(), Config.overlap_policy(), Config.misfire_policy(), pos_integer(), String.t()) :: map()
  defp options_map(name, overlap, misfire, timeout_ms, time_zone) do
    %{name: name, overlap: overlap, misfire: misfire, timeout_ms: timeout_ms, time_zone: time_zone}
  end

  # Rejects duplicate and unsupported options.
  @spec validate_options(term()) :: :ok | {:error, Error.t()}
  defp validate_options(options) do
    keys = if Keyword.keyword?(options), do: Keyword.keys(options), else: []

    if Keyword.keyword?(options) and Enum.uniq(keys) == keys and keys -- @allowed_options == [],
      do: :ok,
      else: invalid(:options, :supported_unique_keyword_list)
  end

  # Requires a release-safe exported callback accepting Trigger before declared arguments.
  @spec validate_mfa(term(), term(), term()) :: :ok | {:error, Error.t()}
  defp validate_mfa(module, function, args)
       when is_atom(module) and is_atom(function) and is_list(args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args) + 1),
      do: :ok,
      else: invalid(:mfa, :exported_function_accepting_trigger_and_arguments)
  end

  defp validate_mfa(_module, _function, _args), do: invalid(:mfa, :module_function_and_list)

  # Restricts names to bounded structural values that do not conflict with IDs.
  @spec validate_name(term()) :: {:ok, name()} | {:error, Error.t()}
  defp validate_name(nil), do: {:ok, nil}
  defp validate_name(name) when is_atom(name), do: {:ok, name}
  defp validate_name(name) when is_tuple(name) and tuple_size(name) <= 8, do: {:ok, name}
  defp validate_name(_name), do: invalid(:name, :atom_or_bounded_tuple)

  # Accepts only the two explicit overlap policies.
  @spec validate_overlap(term()) :: {:ok, Config.overlap_policy()} | {:error, Error.t()}
  defp validate_overlap(value) when value in [:allow, :skip], do: {:ok, value}
  defp validate_overlap(_value), do: invalid(:overlap, :allow_or_skip)

  # Accepts only the two explicit missed-occurrence policies.
  @spec validate_misfire(term()) :: {:ok, Config.misfire_policy()} | {:error, Error.t()}
  defp validate_misfire(value) when value in [:fire_once, :skip], do: {:ok, value}
  defp validate_misfire(_value), do: invalid(:misfire, :fire_once_or_skip)

  # Validates one callback timeout against the configured hard maximum.
  @spec validate_timeout(keyword(), Config.t()) :: {:ok, pos_integer()} | {:error, Error.t()}
  defp validate_timeout(options, config) do
    timeout_ms = Keyword.get(options, :execution_timeout_ms, Config.default_execution_timeout_ms(config))

    if is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= Config.max_execution_timeout_ms(config),
      do: {:ok, timeout_ms},
      else: invalid(:execution_timeout_ms, :configured_range)
  end

  # Validates one bounded explicit timezone name.
  @spec validate_time_zone(term()) :: {:ok, String.t()} | {:error, Error.t()}
  defp validate_time_zone(value) when is_binary(value) and byte_size(value) in 1..128, do: {:ok, value}
  defp validate_time_zone(_value), do: invalid(:time_zone, :non_empty_binary)

  # Builds a bounded validation error without callback arguments.
  @spec invalid(atom(), atom()) :: {:error, Error.t()}
  defp invalid(field, expected), do: {:error, Error.invalid_schedule(%{field: field, expected: expected})}
end
