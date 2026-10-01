defmodule Periodical.Schedule do
  @moduledoc "Represents and calculates one recurring or one-time schedule without processes or implicit clocks."

  alias Periodical.Recurrence
  alias Periodical.Error

  @enforce_keys [:kind, :value]
  defstruct @enforce_keys

  @typedoc "A recurring rule or one exact future instant."
  @type t :: %__MODULE__{kind: :once, value: DateTime.t()} | %__MODULE__{kind: :recurring, value: Recurrence.t()}

  ##
  ## Public API
  ##

  # Public functions

  @doc "Builds a recurring schedule from a recurrence struct or expression."

  @spec recurring(Recurrence.t() | String.t()) :: {:ok, t()} | {:error, Error.t()}
  def recurring(%Ephemeris.Rule{} = recurrence), do: {:ok, %__MODULE__{kind: :recurring, value: recurrence}}

  def recurring(expression) when is_binary(expression) do
    case Recurrence.parse(expression) do
      {:ok, recurrence} -> recurring(recurrence)
      {:error, error} -> {:error, error}
    end
  end

  def recurring(_value), do: {:error, Error.invalid_schedule(%{field: :recurrence})}

  @doc "Builds a one-time schedule strictly after an explicit reference instant."
  @spec once(DateTime.t(), DateTime.t()) :: {:ok, t()} | {:error, Error.t()}
  def once(%DateTime{} = occurrence, %DateTime{} = reference) do
    if DateTime.compare(occurrence, reference) == :gt,
      do: {:ok, %__MODULE__{kind: :once, value: occurrence}},
      else: {:error, Error.invalid_schedule(%{field: :datetime, expected: :future})}
  end

  def once(_occurrence, _reference), do: {:error, Error.invalid_schedule(%{field: :datetime})}

  @doc "Returns the first occurrence strictly after an explicit reference instant."
  @spec next(t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, Error.t()}
  def next(%__MODULE__{kind: :recurring, value: recurrence}, reference), do: Recurrence.next(recurrence, reference)

  def next(%__MODULE__{kind: :once, value: occurrence}, reference) do
    if DateTime.compare(occurrence, reference) == :gt,
      do: {:ok, occurrence},
      else: {:error, Error.invalid_schedule(%{reason: :no_future_occurrence})}
  end

  @doc "Returns the next recurring occurrence while preserving cadence unless time has advanced past it."
  @spec following(t(), DateTime.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | :complete | {:error, Error.t()}
  def following(%__MODULE__{kind: :once}, _occurrence, _now), do: :complete

  def following(%__MODULE__{kind: :recurring, value: recurrence}, occurrence, now) do
    with {:ok, anchored} <- Recurrence.next(recurrence, occurrence) do
      if DateTime.compare(anchored, now) == :gt,
        do: {:ok, anchored},
        else: Recurrence.next(recurrence, now)
    end
  end

  @doc "Returns a non-negative millisecond delay from a reference to an occurrence."
  @spec delay_ms(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def delay_ms(occurrence, reference), do: max(DateTime.diff(occurrence, reference, :millisecond), 0)
end
