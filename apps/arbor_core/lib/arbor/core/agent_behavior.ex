defmodule Arbor.Core.AgentBehavior do
  @moduledoc """
  Common behavior and helper functions for all Arbor agents.

  This module provides:
  - Callback definitions for agent state management, compliant with `Arbor.Contracts.Agent.Behavior`.
  - Helper macros for common agent patterns
  - Automatic state extraction/restoration support
  - Centralized, event-driven registration with the HordeSupervisor

  ## Usage

      defmodule MyAgent do
        use Arbor.Core.AgentBehavior

        def init(args) do
          state = %{
            agent_id: Keyword.fetch!(args, :agent_id),
            data: Keyword.get(args, :data, %{}),
            status: :ready
          }
          # The registration is handled automatically by AgentBehavior
          {:ok, state, {:continue, :register_with_supervisor}}
        end

        # Optional: Override to provide agent-specific metadata for registration
        @impl Arbor.Core.AgentBehavior
        def get_agent_metadata(state) do
          %{capability: :do_stuff}
        end

        # Optional: Override extract_state if you need custom logic
        @impl Arbor.Core.AgentBehavior
        def extract_state(state) do
          # Default implementation returns {:ok, state}
          {:ok, state}
        end

        # Optional: Override restore_state if you need custom logic
        @impl Arbor.Core.AgentBehavior
        def restore_state(agent_spec, restored_state) do
          # Default implementation returns {:ok, restored_state}
          {:ok, restored_state}
        end

        # Optional: Override to handle registration result
        @impl Arbor.Core.AgentBehavior
        def handle_registration_result(state, {:ok, _}) do
          # Registration was successful
          state
        end
      end
  """

  @behaviour Arbor.Contracts.Agent.Behavior

  @doc """
  Callback for extracting agent state for migration.

  This is called when an agent needs to be migrated to another node.
  The extracted state should be serializable and contain all necessary
  information to restore the agent on another node.

  The default implementation returns the full state wrapped in an `:ok` tuple.
  """
  @callback extract_state(state :: any()) :: {:ok, any()} | {:error, any()}

  @doc """
  Callback for restoring agent state after migration.

  This is called after an agent has been restarted on a new node.
  It receives the agent's specification (initial state) and the extracted
  state from the previous instance.

  The default implementation replaces the current state with the extracted state.
  """
  @callback restore_state(agent_spec :: map(), restored_state :: any()) ::
              {:ok, any()} | {:error, any()}

  @doc """
  Callback for providing agent-specific metadata for registration.

  This is called by the HordeSupervisor after the agent starts.
  The returned map will be merged with runtime metadata and registered
  in the cluster registry.
  """
  @callback get_agent_metadata(state :: any()) :: map()

  @doc """
  Handles the result of an agent's registration attempt.

  After an agent starts, the system may attempt to register it with a central
  registry. This callback informs the agent of the outcome.
  """
  @callback handle_registration_result(
              state :: any(),
              result :: {:ok, any()} | {:error, any()}
            ) :: any()

  @optional_callbacks extract_state: 1,
                      restore_state: 2,
                      get_agent_metadata: 1,
                      handle_registration_result: 2

  # Implement Arbor.Contracts.Agent.Behavior callbacks by delegating to the module's callbacks
  @impl Arbor.Contracts.Agent.Behavior
  def extract_state(state) do
    # This is a default implementation - modules using AgentBehavior will override
    {:ok, state}
  end

  @impl Arbor.Contracts.Agent.Behavior
  def restore_state(_agent_spec, restored_state) do
    # This is a default implementation - modules using AgentBehavior will override
    {:ok, restored_state}
  end

  @impl Arbor.Contracts.Agent.Behavior
  def get_agent_metadata(_state) do
    # This is a default implementation - modules using AgentBehavior will override
    %{}
  end

  @impl Arbor.Contracts.Agent.Behavior
  def handle_registration_result(state, _result) do
    # This is a default implementation - modules using AgentBehavior will override
    state
  end

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour Arbor.Core.AgentBehavior
      @compile {:nowarn_unused_function, [handle_restore_result: 2]}

      require Logger
      alias Arbor.Core.HordeSupervisor

      # Default implementations

      @impl Arbor.Core.AgentBehavior
      def extract_state(state), do: {:ok, state}

      @impl Arbor.Core.AgentBehavior
      def restore_state(_agent_spec, restored_state), do: {:ok, restored_state}

      @impl Arbor.Core.AgentBehavior
      def get_agent_metadata(_state), do: %{}

      @impl Arbor.Core.AgentBehavior
      def handle_registration_result(state, _result), do: state

      # GenServer callbacks for state management

      @impl GenServer
      def handle_call(:extract_state, _from, state) do
        result = extract_state(state)
        {:reply, result, state}
      end

      @impl GenServer
      def handle_call({:restore_state, restored_state}, _from, state) do
        # The current `state` is passed as the `agent_spec`.
        # Note: Default implementation always returns {:ok, term()}, but custom
        # implementations may return {:error, reason}, so we handle both cases.
        result = restore_state(state, restored_state)

        # Use dynamic pattern matching to avoid unreachable clause warnings
        handle_restore_result(result, state)
      end

      # Helper function to handle restore_state results dynamically
      @compile {:nowarn_unused_function, [handle_restore_result: 2]}
      defp handle_restore_result({:ok, new_state}, _state) do
        {:reply, :ok, new_state}
      end

      defp handle_restore_result({:error, reason}, state) do
        Logger.error("Failed to restore agent state.", reason: reason)
        {:reply, {:error, reason}, state}
      end

      defp handle_restore_result(other, state) do
        Logger.error("Invalid restore_state return value.", return: other)
        {:reply, {:error, :invalid_return}, state}
      end

      @impl GenServer
      def handle_call(:get_agent_metadata, _from, state) do
        {:reply, get_agent_metadata(state), state}
      end

      @impl GenServer
      def handle_call(:get_state, _from, state) do
        {:reply, state, state}
      end

      # Centralized registration logic
      @impl GenServer
      def handle_continue(:register_with_supervisor, state) do
        supervisor_impl = Application.get_env(:arbor_core, :supervisor_impl, :auto)
        Logger.debug("AgentBehavior: handle_continue called", supervisor_impl: supervisor_impl)

        if supervisor_impl == :mock do
          Logger.debug("AgentBehavior: Skipping registration due to mock supervisor")
          {:noreply, state}
        else
          # Start non-blocking registration process
          retry_config = Application.get_env(:arbor_core, :agent_retry, [])
          retries = Keyword.get(retry_config, :retries, 3)
          initial_delay = Keyword.get(retry_config, :initial_delay, 250)

          Logger.debug("AgentBehavior: Starting registration process",
            retries: retries,
            initial_delay: initial_delay
          )

          # Send message to self to start the first attempt immediately.
          Process.send(self(), {:attempt_registration, retries, initial_delay}, [])
          {:noreply, state}
        end
      end

      @impl GenServer
      def handle_info({:attempt_registration, retries_left, delay}, state) do
        agent_id = Map.fetch!(state, :agent_id)
        metadata = get_agent_metadata(state)

        Logger.debug("AgentBehavior: Attempting registration",
          agent_id: agent_id,
          retries_left: retries_left
        )

        case HordeSupervisor.register_agent(self(), agent_id, metadata) do
          {:ok, pid} ->
            Logger.debug("AgentBehavior: Agent successfully registered with supervisor")
            Logger.debug("Agent successfully registered with supervisor", agent_id: agent_id)
            new_state = handle_registration_result(state, {:ok, pid})
            {:noreply, new_state}

          {:error, reason} ->
            Logger.debug("AgentBehavior: Registration failed",
              reason: reason
            )

            if retries_left > 0 do
              Logger.warning("Failed to register with supervisor, retrying...",
                agent_id: agent_id,
                reason: reason,
                retries_left: retries_left - 1,
                delay_ms: delay
              )

              Process.send_after(
                self(),
                {:attempt_registration, retries_left - 1, delay * 2},
                delay
              )

              {:noreply, state}
            else
              Logger.error(
                "Failed to register with supervisor after multiple attempts, stopping.",
                agent_id: agent_id,
                reason: reason
              )

              final_reason = :max_retries_reached
              new_state = handle_registration_result(state, {:error, final_reason})
              {:stop, {:registration_failed, final_reason}, new_state}
            end
        end
      end

      # Allow callbacks to be overridden
      defoverridable extract_state: 1,
                     restore_state: 2,
                     get_agent_metadata: 1,
                     handle_registration_result: 2
    end
  end
end
