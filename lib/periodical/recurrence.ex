defmodule Periodical.Recurrence do
  @moduledoc """
  A recurrence rule, expressed in RFC 5545 `RRULE` syntax.

  `RRULE` is the iCalendar standard for recurring events, so a rule written here
  is the same one a calendar application would understand:

      FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE
      FREQ=MONTHLY;BYDAY=-1SU
      FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1

  The `RRULE:` prefix is optional — both `"FREQ=DAILY"` and `"RRULE:FREQ=DAILY"`
  parse.

  Rules hold no process, callback, timer or implicit current time: every
  calculation takes an explicit reference `DateTime`.

  ## Examples

      iex> {:ok, rule} = Periodical.Recurrence.parse("FREQ=MONTHLY;BYDAY=-1SU")
      iex> Periodical.Recurrence.next(rule, ~U[2026-01-01 09:00:00Z])
      {:ok, ~U[2026-01-25 09:00:00Z]}
  """

  alias Periodical.Error

  @enforce_keys [:expression, :rule]
  defstruct @enforce_keys

  @typedoc "A parsed recurrence rule and the expression it came from."
  @type t :: %__MODULE__{expression: String.t(), rule: term()}

  # An occurrence far enough ahead is indistinguishable from none. A rule such
  # as `FREQ=YEARLY;BYMONTHDAY=29;BYMONTH=2` skips three years at a time, so the
  # limit is generous; without one, a rule matching nothing would search forever.
  @search_limit 500

  ##
  ## Public API
  ##

  @doc """
  Parses an RFC 5545 `RRULE` expression.

  Returns `{:error, Periodical.Error.t()}` when the expression is not a valid
  rule, rather than raising, so a rule arriving from configuration or a user can
  be rejected cleanly.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def parse(expression) when is_binary(expression) do
    normalized = normalize(expression)

    case ICal.Recurrence.from_ics(normalized) do
      {:ok, rule} -> {:ok, %__MODULE__{expression: normalized, rule: rule}}
      %{} = rule -> {:ok, %__MODULE__{expression: normalized, rule: rule}}
      _invalid -> invalid(expression)
    end
  rescue
    _error -> invalid(expression)
  end

  def parse(_expression), do: {:error, Error.invalid_schedule(%{field: :recurrence})}

  @doc """
  Parses an expression, raising `Periodical.Error` when it is invalid.
  """
  @spec parse!(String.t()) :: t()
  def parse!(expression) do
    case parse(expression) do
      {:ok, recurrence} -> recurrence
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns the first occurrence strictly after `reference`.

  Strictly after, so calling it with an occurrence returns the *following* one
  rather than the same instant forever.
  """
  @spec next(t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, Error.t()}
  def next(%__MODULE__{rule: rule}, %DateTime{} = reference) do
    %{rrule: rule, dtstart: reference}
    |> ICal.Recurrence.stream()
    |> Stream.take(@search_limit)
    |> Enum.find(&(DateTime.compare(&1, reference) == :gt))
    |> case do
      %DateTime{} = occurrence -> {:ok, occurrence}
      nil -> {:error, Error.invalid_schedule(%{reason: :no_future_occurrence})}
    end
  rescue
    _error -> {:error, Error.invalid_schedule(%{reason: :no_future_occurrence})}
  end

  ##
  ## Private Functions
  ##

  # Accepts an expression with or without the `RRULE:` prefix the standard uses
  # inside an iCalendar document, so configuration need not carry it.
  @spec normalize(String.t()) :: String.t()
  defp normalize("RRULE:" <> _rest = expression), do: expression
  defp normalize(expression), do: "RRULE:" <> expression

  # Builds the single failure this module reports for an unusable expression.
  @spec invalid(String.t()) :: {:error, Error.t()}
  defp invalid(expression),
    do: {:error, Error.invalid_schedule(%{field: :recurrence, expression: expression})}
end
