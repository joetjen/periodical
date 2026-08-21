defmodule Periodical.Application do
  @moduledoc false

  use Application

  alias Periodical.{Config, Scheduler}

  ##
  ## Callback Implementations
  ##

  # Behaviour callbacks

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid(), Config.t()} | {:error, term()}
  def start(_type, _arguments) do
    with {:ok, config} <- Config.load(),
         {:ok, supervisor} <- Supervisor.start_link(children(config), supervisor_options()) do
      {:ok, supervisor, config}
    end
  end

  ##
  ## Private Functions
  ##

  # Internal helpers

  # Starts bounded callback ownership before the scheduler that dispatches into it.
  @spec children(Config.t()) :: [Supervisor.child_spec()]
  defp children(config) do
    task_supervisor =
      Supervisor.child_spec(
        {Task.Supervisor, name: Periodical.TaskSupervisor, max_children: Config.max_in_flight(config)},
        id: Periodical.TaskSupervisor
      )

    scheduler =
      Supervisor.child_spec(
        {Scheduler, config},
        shutdown: Config.shutdown_timeout_ms(config)
      )

    [task_supervisor, scheduler]
  end

  # Returns the stable root-supervisor identity and dependent restart strategy.
  @spec supervisor_options() :: keyword()
  defp supervisor_options, do: [strategy: :rest_for_one, name: Periodical.Supervisor]
end
