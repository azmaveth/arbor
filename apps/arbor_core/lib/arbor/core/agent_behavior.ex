defmodule Arbor.Core.AgentBehavior do
  @moduledoc """
  Common behavior and helper functions for all Arbor agents.

  This module provides:
  - Callback definitions for agent state management
  - Helper macros for common agent patterns
  - Automatic state extraction/restoration support

  ## Usage

      defmodule MyAgent do
        use Arbor.Core.AgentBehavior
        
        def init(args) do
          state = %{
            data: Keyword.get(args, :data, %{}),
            status: :ready
          }
          {:ok, state}
        end
        
        # Optional: Override extract_state if you need custom logic
        def extract_state(state) do
          # Default implementation returns the full state
          state
        end
        
        # Optional: Override restore_state if you need custom logic
        def restore_state(state, extracted_state) do
          # Default implementation replaces the full state
          extracted_state
        end
      end
  """

  @doc """
  Callback for extracting agent state for migration.

  This is called when an agent needs to be migrated to another node.
  The extracted state should be serializable and contain all necessary
  information to restore the agent on another node.

  The default implementation returns the full state.
  """
  @callback extract_state(state :: any()) :: any()

  @doc """
  Callback for restoring agent state after migration.

  This is called after an agent has been restarted on a new node.
  It receives the current (likely initial) state and the extracted
  state from the previous instance.

  The default implementation replaces the current state with the extracted state.
  """
  @callback restore_state(current_state :: any(), extracted_state :: any()) :: any()

  @optional_callbacks extract_state: 1, restore_state: 2

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour Arbor.Core.AgentBehavior
      require Logger

      # Default implementations

      @impl Arbor.Core.AgentBehavior
      def extract_state(state), do: state

      @impl Arbor.Core.AgentBehavior
      def restore_state(_current_state, extracted_state), do: extracted_state

      # GenServer callbacks for state management

      def handle_call(:extract_state, _from, state) do
        extracted = extract_state(state)
        {:reply, extracted, state}
      end

      def handle_call({:restore_state, extracted_state}, _from, state) do
        new_state = restore_state(state, extracted_state)
        {:reply, :ok, new_state}
      end

      def handle_call(:get_state, _from, state) do
        {:reply, state, state}
      end

      # Helper function for self-registration
      @doc false
      def register_self(agent_id, metadata \\ %{}) do
        case Arbor.Core.HordeRegistry.register_name(agent_id, self(), metadata) do
          :ok ->
            Logger.info("Agent registered successfully",
              agent_id: agent_id,
              pid: inspect(self()),
              node: node()
            )

            :ok

          {:error, :name_taken} = error ->
            Logger.error("Failed to register agent - name already taken",
              agent_id: agent_id,
              pid: inspect(self())
            )

            error

          {:error, reason} = error ->
            Logger.error("Failed to register agent",
              agent_id: agent_id,
              pid: inspect(self()),
              reason: inspect(reason)
            )

            error
        end
      end

      # Allow callbacks to be overridden
      defoverridable extract_state: 1, restore_state: 2
    end
  end
end
