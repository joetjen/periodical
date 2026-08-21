defmodule Periodical.Recurrence do
  @moduledoc """
  A recurrence rule, written as RFC 5545 `RRULE` or as plain English.

  Both forms describe the same thing and either is accepted:

      FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE
      every 2 weeks on Monday and Wednesday

      FREQ=MONTHLY;BYDAY=-1SU
      every last Sunday of the month

  `RRULE` is the portable form a calendar application understands; English is
  the readable form for a configuration file. Parsing either yields the same
  rule, and `to_rrule/1` and `to_sentence/1` render it back in either.

  Rules hold no process, callback, timer or implicit current time: every
  calculation takes an explicit reference `DateTime`.

  The parsing, rendering and occurrence arithmetic all live in
  [Ephemeris](https://github.com/joetjen/ephemeris); this module is the
  boundary that keeps Periodical's own error type at its edges.

  ## Examples

      iex> {:ok, rule} = Periodical.Recurrence.parse("every last Sunday of the month")
      iex> Periodical.Recurrence.next(rule, ~U[2026-01-01 09:00:00Z])
      {:ok, ~U[2026-01-25 09:00:00Z]}
  """

  alias Periodical.Error

  @typedoc "A parsed recurrence rule."
  @type t :: Ephemeris.Rule.t()

  ##
  ## Public API
  ##

  @doc """
  Parses an `RRULE` expression or an English sentence.

  Returns `{:error, Periodical.Error.t()}` rather than raising, so a rule
  arriving from configuration or a user can be rejected cleanly.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def parse(expression) when is_binary(expression) do
    case Ephemeris.parse(expression) do
      {:ok, rule} -> {:ok, rule}
      {:error, error} -> {:error, invalid(expression, error)}
    end
  end

  def parse(_expression), do: {:error, Error.invalid_schedule(%{field: :recurrence})}

  @doc "Parses an expression, raising `Periodical.Error` when it is invalid."
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
  def next(%Ephemeris.Rule{} = rule, %DateTime{} = reference) do
    case Ephemeris.next(rule, reference) do
      {:ok, occurrence} -> {:ok, occurrence}
      {:error, _error} -> {:error, Error.invalid_schedule(%{reason: :no_future_occurrence})}
    end
  end

  @doc "Renders a rule as RFC 5545 `RRULE` text."
  @spec to_rrule(t()) :: String.t()
  defdelegate to_rrule(rule), to: Ephemeris

  @doc "Renders a rule as an English sentence."
  @spec to_sentence(t()) :: String.t()
  defdelegate to_sentence(rule), to: Ephemeris

  ##
  ## Private Functions
  ##

  # Restates an Ephemeris failure as Periodical's own, keeping the underlying
  # code in the details so the cause is not lost.
  @spec invalid(String.t(), Ephemeris.Error.t()) :: Error.t()
  defp invalid(expression, %Ephemeris.Error{code: code}),
    do: Error.invalid_schedule(%{field: :recurrence, expression: expression, reason: code})
end
