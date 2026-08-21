defmodule Periodical.Gate do
  @moduledoc """
  The contract for gating job execution on external health.

  A scheduler can be told to stop firing triggers while a dependency it needs is
  unhealthy, and to resume when it recovers. Periodical does not implement health
  checking itself and does not depend on any library that does — it subscribes
  to whatever you configure:

      config :periodical, gate: MyApp.HealthGate

  With no gate configured, a queue given `gate: nil` runs unconditionally, which
  is the default. Configuring a queue with a gate name while no gate module is
  available is an error rather than a silent free pass: a scheduler that was meant
  to pause under load must not quietly run at full speed instead.

  An implementation reports the gate's current state on subscription and then
  sends the subscribing process a message on every transition:

      {:periodical_gate, gate, :open}
      {:periodical_gate, gate, :closed, reason}

  The closed message carries a reason so an operator can tell *why* work
  paused; the open message needs none.
  """

  @typedoc "The name of a gate, as understood by the configured implementation."
  @type gate :: atom()

  @doc "Subscribes the calling process to `gate`, reporting its current state."
  @callback subscribe(gate()) :: {:ok, :open | :closed} | {:error, term()}

  @doc "Unsubscribes the calling process from `gate`."
  @callback unsubscribe(gate()) :: :ok

  ##
  ## Public API
  ##

  @doc "Returns the configured gate implementation, or `nil` when none is set."
  @spec implementation() :: module() | nil
  def implementation, do: Application.get_env(:periodical, :gate)
end
