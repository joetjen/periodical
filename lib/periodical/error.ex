defmodule Periodical.Error do
  @moduledoc """
  Defines the stable, typed failures returned by Periodical.

  Every failure carries a machine-readable `:code`, a fixed human-readable
  `:message`, and free-form `:details` describing the specific occurrence. The
  code is the stable part: match on it rather than on message text.

  Each code has a constructor of the same name:

      iex> error = Periodical.Error.overloaded(%{limit: 100})
      iex> {error.code, error.details}
      {:overloaded, %{limit: 100}}
  """

  @typedoc "An error owned by Periodical."
  @type t :: %__MODULE__{code: atom(), message: String.t(), details: term()}

  defexception [:code, :message, details: %{}]

  @messages [
    dependency_unavailable: "A configured optional dependency is unavailable",
    drain_timeout: "Scheduler drain deadline expired",
    duplicate_name: "A schedule with this name already exists",
    invalid_config: "Periodical configuration is invalid",
    invalid_schedule: "Schedule definition is invalid",
    overloaded: "Schedule capacity has been reached",
    schedule_not_found: "Schedule was not found",
    shutting_down: "Scheduler is shutting down"
  ]

  for {code, message} <- @messages do
    @doc "Builds the `#{inspect(code)}` error: #{message}."
    @spec unquote(code)(term()) :: t()
    def unquote(code)(details \\ %{}),
      do: %__MODULE__{code: unquote(code), message: unquote(message), details: details}
  end

  @doc "Returns every code this module defines, for exhaustiveness checks."
  @spec codes() :: [atom()]
  def codes, do: unquote(Keyword.keys(@messages))

  @impl true
  @spec exception(keyword()) :: t()
  def exception(options) when is_list(options) do
    %__MODULE__{
      code: Keyword.get(options, :code, :invalid_schedule),
      message: Keyword.get(options, :message, "Schedule definition is invalid"),
      details: Keyword.get(options, :details, %{})
    }
  end

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{message: message}), do: message
end
