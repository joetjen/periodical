defmodule Periodical.Telemetry.Context do
  @moduledoc """
  The contract for propagating process context from enqueue to execution.

  Periodical runs a job in a different process from the one that enqueued it, so
  anything held in process state — logger metadata, a trace span — does not
  follow it. An implementation captures that state in the enqueueing process
  and restores it around execution.

  Kept as a behaviour so Periodical depends on no particular tracing library. See
  `Periodical.Telemetry.LoggerContext` for the default.
  """

  @doc "Captures the calling process's context."
  @callback capture() :: term()

  @doc "Runs `function` with a captured context applied, restoring what was there."
  @callback with(context :: term(), function :: (-> result)) :: result when result: var
end
