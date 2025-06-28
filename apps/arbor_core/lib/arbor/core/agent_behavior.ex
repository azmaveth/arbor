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

  # Define the callbacks for modules that use this behavior
  @callback extract_state(state :: any()) :: {:ok, any()} | {:error, any()}
  @callback restore_state(agent_spec :: map(), restored_state :: any()) ::
              {:ok, any()} | {:error, any()}
  @callback get_agent_metadata(state :: any()) :: map()
  @callback handle_registration_result(state :: any(), result :: {:ok, any()} | {:error, any()}) ::
              any()

  @optional_callbacks extract_state: 1,
                      restore_state: 2,
                      get_agent_metadata: 1,
                      handle_registration_result: 2

  # Implement Arbor.Contracts.Agent.Behavior callbacks by delegating to the module's callbacks
  @doc """
  Extracts the serializable state of an agent for persistence.

  This callback is called when the agent's state needs to be checkpointed,
  for example, before a graceful shutdown or during periodic state saving.

  ## Parameters
  - `state` - The current state of the agent.

  ## Returns
  - `{:ok, serializable_state}` - On success, where `serializable_state` is a
    term that can be serialized.
  - `{:error, reason}` - If state extraction fails.

  ## Default Implementation
  The default implementation returns `{:ok, state}`, assuming the entire agent
  state is serializable. Modules using `AgentBehavior` should override this
  callback if they need to select a subset of the state or transform it into a
  serializable format.

  ## Example
      @impl Arbor.Core.AgentBehavior
      def extract_state(state) do
        # Only persist the :data field
        {:ok, Map.get(state, :data)}
      end
  """
  @spec extract_state(state :: map()) :: {:ok, term()} | {:error, any()}
  @impl Arbor.Contracts.Agent.Behavior
  @dialyzer {:nowarn_function, extract_state: 1}
  def extract_state(state) do
    # This is a default implementation - modules using AgentBehavior will override
    {:ok, state}
  end

  @doc """
  Restores an agent's state from a previously extracted state.

  This callback is called when an agent is being restored from a checkpoint.

  ## Parameters
  - `agent_spec` - The initial state or arguments of the agent when it was started.
    This is the agent's state *before* restoration.
  - `restored_state` - The `term()` that was previously extracted by `extract_state/1`.

  ## Returns
  - `{:ok, new_state}` - On success, where `new_state` is the fully restored
    agent state.
  - `{:error, reason}` - If restoration fails.

  ## Default Implementation
  The default implementation returns `{:ok, restored_state}`, assuming the
  restored term can be used directly as the new agent state. Modules using
  `AgentBehavior` should override this callback to merge the restored state with
  the initial agent spec or perform transformations to reconstruct the full agent state.

  ## Example
      @impl Arbor.Core.AgentBehavior
      def restore_state(current_state, restored_data) do
        new_state = Map.put(current_state, :data, restored_data)
        {:ok, new_state}
      end
  """
  @spec restore_state(agent_spec :: map(), restored_state :: term()) ::
          {:ok, map()} | {:error, any()}
  @impl Arbor.Contracts.Agent.Behavior
  @dialyzer {:nowarn_function, restore_state: 2}
  def restore_state(_agent_spec, restored_state) do
    # This is a default implementation - modules using AgentBehavior will override
    {:ok, restored_state}
  end

  @doc """
  Provides metadata about the agent for registration with the supervisor.

  This callback is called during the agent registration process, after `init/1`,
  to gather information about the agent's capabilities and type.

  ## Parameters
  - `state` - The current state of the agent.

  ## Returns
  - A `map()` containing agent metadata (e.g., `%{type: :my_agent, capabilities: [:read, :write]}`).

  ## Default Implementation
  The default implementation returns an empty map (`%{}`), providing no metadata.
  Modules using `AgentBehavior` must override this callback to provide meaningful
  metadata for agent discovery and interaction.

  ## Example
      @impl Arbor.Core.AgentBehavior
      def get_agent_metadata(state) do
        %{
          type: :file_processor,
          supported_formats: [".txt", ".csv"],
          working_dir: state.working_dir
        }
      end
  """
  @spec get_agent_metadata(state :: map()) :: map()
  @impl Arbor.Contracts.Agent.Behavior
  def get_agent_metadata(_state) do
    # This is a default implementation - modules using AgentBehavior will override
    %{}
  end

  @doc """
  Handles the outcome of the agent registration process.

  This callback is called after the registration attempt with the supervisor
  completes, either successfully or after all retries have failed.

  ## Parameters
  - `state` - The current state of the agent.
  - `result` - The registration result, which is `{:ok, pid}` on success or
    `{:error, reason}` on failure.

  ## Returns
  - A `new_state` which will become the agent's new state.

  ## Default Implementation
  The default implementation returns the original `state` unchanged, effectively
  ignoring the registration result. Modules using `AgentBehavior` can override
  this to update the agent's state based on the registration outcome.

  ## Example
      @impl Arbor.Core.AgentBehavior
      def handle_registration_result(state, {:ok, _pid}) do
        Map.put(state, :status, :registered)
      end

      def handle_registration_result(state, {:error, reason}) do
        Logger.error("Failed to register: \#{inspect(reason)}")
        Map.put(state, :status, :registration_failed)
      end
  """
  @spec handle_registration_result(state :: map(), result :: {:ok, pid()} | {:error, any()}) ::
          new_state :: map()
  @impl true
  def handle_registration_result(state, _result) do
    # This is a default implementation - modules using AgentBehavior will override
    state
  end

  # Private helper functions to generate AST fragments

  defp generate_default_callbacks_ast do
    quote do
      # Default implementations

      @impl Arbor.Core.AgentBehavior
      def extract_state(state), do: {:ok, state}

      @impl Arbor.Core.AgentBehavior
      def restore_state(_agent_spec, restored_state), do: {:ok, restored_state}

      @impl Arbor.Core.AgentBehavior
      def get_agent_metadata(_state), do: %{}

      @impl true
      def handle_registration_result(state, _result), do: state
    end
  end

  defp generate_genserver_callbacks_ast do
    quote do
      # GenServer callbacks for state management

      @impl true
      def handle_call(:extract_state, _from, state) do
        result = extract_state(state)
        {:reply, result, state}
      end

      @impl true
      def handle_call({:restore_state, restored_state}, _from, state) do
        # The current `state` is passed as the `agent_spec`.
        # Note: Default implementation always returns {:ok, term()}, but custom
        # implementations may return {:error, reason}, so we handle both cases.
        result = restore_state(state, restored_state)
        handle_restore_result(result, state)
      end

      @impl true
      def handle_call(:get_agent_metadata, _from, state) do
        {:reply, get_agent_metadata(state), state}
      end

      @impl true
      def handle_call(:get_state, _from, state) do
        {:reply, state, state}
      end
    end
  end

  defp generate_registration_handlers_ast do
    quote do
      # Centralized registration logic
      @impl true
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

      @impl true
      def handle_info({:attempt_registration, retries_left, delay}, state) do
        agent_id = Map.fetch!(state, :agent_id)
        metadata = get_agent_metadata(state)

        Logger.debug("AgentBehavior: Attempting registration",
          agent_id: agent_id,
          retries_left: retries_left
        )

        supervisor_impl = get_supervisor_impl()

        case supervisor_impl.register_agent(self(), agent_id, metadata) do
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
    end
  end

  defp generate_helper_functions_ast do
    [
      generate_restore_handlers_ast(),
      generate_supervisor_helpers_ast()
    ]
  end

  defp generate_restore_handlers_ast do
    quote do
      # Helper function to handle restore_state results
      defp handle_restore_result({:ok, new_state}, _state) do
        {:reply, :ok, new_state}
      end

      defp handle_restore_result({:error, reason}, state) do
        Logger.error("Failed to restore agent state.", reason: reason)
        {:reply, {:error, reason}, state}
      end

      defp handle_restore_result(other, state) do
        Logger.error("Invalid restore_state return value: #{inspect(other)}")
        {:reply, {:error, :invalid_return}, state}
      end
    end
  end

  defp generate_supervisor_helpers_ast do
    quote do
      # Helper function to get supervisor implementation
      defp get_supervisor_impl do
        supervisor_config = Application.get_env(:arbor_core, :supervisor_impl, :auto)

        case supervisor_config do
          :mock -> Arbor.Test.Mocks.LocalSupervisor
          :horde -> Arbor.Core.HordeSupervisor
          :auto -> get_auto_supervisor()
          module when is_atom(module) -> module
        end
      end

      defp get_auto_supervisor do
        if Application.get_env(:arbor_core, :env) == :test do
          Arbor.Test.Mocks.LocalSupervisor
        else
          Arbor.Core.HordeSupervisor
        end
      end
    end
  end

  defmacro __using__(_opts) do
    [
      quote do
        use GenServer
        @behaviour Arbor.Core.AgentBehavior
        @compile {:nowarn_unused_function, [handle_restore_result: 2]}

        require Logger
        alias Arbor.Core.HordeSupervisor
      end,
      generate_default_callbacks_ast(),
      generate_genserver_callbacks_ast(),
      generate_registration_handlers_ast(),
      generate_helper_functions_ast(),
      quote do
        # Allow callbacks to be overridden
        defoverridable extract_state: 1,
                       restore_state: 2,
                       get_agent_metadata: 1,
                       handle_registration_result: 2
      end
    ]
  end
end
