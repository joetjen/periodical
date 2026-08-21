defmodule Periodical.Timer do
  @moduledoc "Defines the replaceable one-shot timer boundary used by the scheduler."

  @doc "Schedules a message after a non-negative millisecond duration."
  @callback send_after(non_neg_integer(), pid(), term()) :: {:ok, term()} | {:error, term()}

  @doc "Cancels a previously returned timer reference."
  @callback cancel(term()) :: :ok | {:error, term()}
end

defmodule Periodical.Timer.System do
  @moduledoc false

  @behaviour Periodical.Timer

  ##
  ## Callback Implementations
  ##

  # Timer operations

  @impl true
  @spec send_after(non_neg_integer(), pid(), term()) :: {:ok, term()} | {:error, term()}
  def send_after(duration_ms, destination, message),
    do: :timer.send_after(duration_ms, destination, message)

  @impl true
  @spec cancel(term()) :: :ok | {:error, term()}
  def cancel(timer_ref) do
    _ignored = :timer.cancel(timer_ref)
    :ok
  end
end
