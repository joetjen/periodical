unless Code.ensure_loaded?(ASCO.HealthCheck) do
  defmodule ASCO.HealthCheck do
    @moduledoc false
    use Agent

    def start_link(_opts \\ []) do
      Agent.start(fn -> default_state() end, name: __MODULE__)
    end

    def reset(opts \\ []) do
      ensure_started()

      Agent.update(__MODULE__, fn _state ->
        %{
          startup_complete?: Keyword.get(opts, :startup_complete?, true),
          callbacks: [],
          fail_startup_complete?: Keyword.get(opts, :fail_startup_complete?, false),
          fail_callback_registration?: Keyword.get(opts, :fail_callback_registration?, false)
        }
      end)

      :ok
    end

    def startup_complete? do
      ensure_started()

      state = Agent.get(__MODULE__, & &1)

      if state.fail_startup_complete? do
        raise "startup_complete? failure"
      else
        state.startup_complete?
      end
    end

    def on_startup_complete(callback) when is_function(callback, 0) do
      ensure_started()

      state = Agent.get(__MODULE__, & &1)

      if state.fail_callback_registration? do
        raise "on_startup_complete failure"
      end

      Agent.get_and_update(__MODULE__, fn state ->
        {:ok, %{state | callbacks: [callback | state.callbacks]}}
      end)
    end

    def mark_startup_complete do
      ensure_started()

      callbacks =
        Agent.get_and_update(__MODULE__, fn state ->
          {state.callbacks, %{state | startup_complete?: true, callbacks: []}}
        end)

      Enum.each(Enum.reverse(callbacks), fn callback -> callback.() end)
      :ok
    end

    defp ensure_started do
      case Process.whereis(__MODULE__) do
        nil ->
          {:ok, _pid} = start_link([])
          :ok

        _pid ->
          :ok
      end
    end

    defp default_state do
      %{
        startup_complete?: true,
        callbacks: [],
        fail_startup_complete?: false,
        fail_callback_registration?: false
      }
    end
  end

  defmodule ASCO.HealthCheck.State do
    @moduledoc false

    def complete_startup do
      ASCO.HealthCheck.mark_startup_complete()
    end
  end
end

ExUnit.start()
