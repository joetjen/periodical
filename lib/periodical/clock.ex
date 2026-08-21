defmodule Periodical.Clock do
  @moduledoc "Defines the wall-clock boundary used for schedule calculation."

  @doc "Returns the current instant in an explicit timezone."
  @callback now(Calendar.time_zone()) :: {:ok, DateTime.t()} | {:error, term()}
end

defmodule Periodical.Clock.System do
  @moduledoc false

  @behaviour Periodical.Clock

  ##
  ## Callback Implementations
  ##

  # Clock access

  @impl true
  @spec now(Calendar.time_zone()) :: {:ok, DateTime.t()} | {:error, term()}
  def now(time_zone), do: DateTime.now(time_zone)
end
