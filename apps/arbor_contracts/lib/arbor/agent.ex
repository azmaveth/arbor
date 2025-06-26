defmodule Arbor.Agent do
  @moduledoc """
  Defines the contract for all agents in the Arbor system.

  This behaviour establishes the fundamental interface that all agents must implement,
  providing callbacks for initialization, message handling, capability management,
  state persistence, and termination.

  ## Usage

  To implement an agent, use this behaviour and provide implementations for all callbacks:

      defmodule MyAgent do
        @behaviour Arbor.Agent

        @impl true
        @spec init(keyword()) :: {:ok, state()} | {:stop, reason()}
        def init(args) do
          {:ok, %{my_state: args[:initial_value]}}
        end

        @impl true
        @spec handle_message(Message.t(), state()) :: 
                {:noreply, state()} | {:reply, term(), state()} | {:stop, reason(), state()}
        def handle_message(envelope, state) do
          # Handle incoming message
          {:noreply, state}
        end

        # ... implement other callbacks
      end

  ## Agent Lifecycle

  1. **Initialization**: `init/1` is called when the agent starts
  2. **Message Processing**: `handle_message/2` processes incoming messages
  3. **Capability Management**: `handle_capability/2` handles capability grants
  4. **State Persistence**: `export_state/1` and `import_state/1` for persistence
  5. **Termination**: `terminate/2` for cleanup

  ## State Management

  Agents maintain both:
  - **Custom State**: Domain-specific state managed by the implementing module
  - **Base State**: Common infrastructure state (ID, capabilities, metadata)

  The base state is managed by `Arbor.Core.Agents.BaseAgent`, while custom state
  is managed by the implementing module.
  """

  alias Arbor.Contracts.Core.{Capability, Message}

  @type agent_id :: String.t()
  @type state :: any()
  @type reason :: atom() | binary() | tuple()

  @doc """
  Initialize the agent with given arguments.

  Called when the agent process starts. Should return the initial state
  or indicate failure.

  ## Parameters

  - `args` - Keyword list of initialization arguments

  ## Returns

  - `{:ok, state}` - Successful initialization with initial state
  - `{:stop, reason}` - Initialization failed, agent should not start

  ## Example

      @spec init(keyword()) :: {:ok, state()} | {:stop, reason()}
      def init(args) do
        initial_value = Keyword.get(args, :initial_value, 0)
        {:ok, %{counter: initial_value, history: []}}
      end
  """
  @callback init(args :: keyword()) ::
              {:ok, state()}
              | {:stop, reason()}

  @doc """
  Handle incoming messages from other agents or the system.

  This is the primary way agents communicate and coordinate. Messages are
  wrapped in `Arbor.Contracts.Core.Message` envelopes that provide routing
  and metadata information.

  ## Parameters

  - `envelope` - Message envelope containing payload and metadata
  - `state` - Current agent state

  ## Returns

  - `{:noreply, new_state}` - Process message without replying
  - `{:reply, reply, new_state}` - Send reply and update state
  - `{:stop, reason, new_state}` - Stop agent after processing

  ## Example

      @spec handle_message(Message.t(), state()) :: 
              {:noreply, state()} | {:reply, term(), state()} | {:stop, reason(), state()}
      def handle_message(%Message{payload: {:increment, amount}}, state) do
        new_counter = state.counter + amount
        new_state = %{state | counter: new_counter}
        {:reply, {:ok, new_counter}, new_state}
      end
  """
  @callback handle_message(
              envelope :: Message.t(),
              state :: state()
            ) ::
              {:noreply, state()}
              | {:reply, reply :: any(), state()}
              | {:stop, reason(), state()}

  @doc """
  Handle capability grants from the security system.

  Called when the agent receives new capabilities that allow it to access
  additional resources or perform new operations.

  ## Parameters

  - `capability` - The capability being granted
  - `state` - Current agent state

  ## Returns

  - `{:ok, new_state}` - Capability accepted and state updated
  - `{:error, reason}` - Capability rejected

  ## Example

      @spec handle_capability(Capability.t(), state()) :: {:ok, state()} | {:error, reason()}
      def handle_capability(%Capability{resource_uri: "arbor://fs/read/" <> _}, state) do
        # Grant file system read access
        {:ok, %{state | can_read_files: true}}
      end
  """
  @callback handle_capability(
              capability :: Capability.t(),
              state :: state()
            ) ::
              {:ok, state()}
              | {:error, reason()}

  @doc """
  Clean up resources when the agent terminates.

  Called when the agent is shutting down, either normally or due to an error.
  Should perform any necessary cleanup.

  ## Parameters

  - `reason` - Reason for termination (`:normal`, `:shutdown`, error, etc.)
  - `state` - Final agent state

  ## Returns

  - `:ok` - Cleanup completed

  ## Example

      @spec terminate(reason(), state()) :: :ok
      def terminate(reason, state) do
        Logger.info("Agent terminating", reason: reason, final_count: state.counter)
        # Close files, network connections, etc.
        :ok
      end
  """
  @callback terminate(reason :: reason(), state :: state()) :: :ok

  @doc """
  Export state for persistence.

  Called periodically to save agent state for recovery after crashes or restarts.
  Should return a serializable representation of the agent's state.

  ## Parameters

  - `state` - Current agent state

  ## Returns

  - `serializable_state` - Map or other serializable data structure

  ## Example

      @spec export_state(state()) :: map()
      def export_state(state) do
        %{
          counter: state.counter,
          history: Enum.take(state.history, 100)  # Limit history size
        }
      end
  """
  @callback export_state(state :: state()) :: map()

  @doc """
  Import state from persistence.

  Called during agent recovery to restore state from a previous export.
  Should reconstruct the agent's state from the persisted data.

  ## Parameters

  - `persisted` - Previously exported state data

  ## Returns

  - `{:ok, state}` - State successfully restored
  - `{:error, reason}` - State restoration failed

  ## Example

      @spec import_state(map()) :: {:ok, state()} | {:error, reason()}
      def import_state(persisted) do
        case persisted do
          %{counter: counter, history: history} when is_integer(counter) ->
            {:ok, %{counter: counter, history: history}}
          _ ->
            {:error, :invalid_persisted_state}
        end
      end
  """
  @callback import_state(persisted :: map()) :: {:ok, state()} | {:error, reason()}

  @doc """
  List capabilities that this agent type can provide.

  Used for dynamic capability discovery. Returns a list of capabilities
  that agents of this type can expose to other agents or clients.

  This is a module-level callback that describes the agent type's potential
  capabilities, not the runtime capabilities of a specific instance.

  ## Returns

  - `capabilities` - List of capability descriptions

  ## Example

      @spec list_capabilities() :: [map()]
      def list_capabilities do
        [
          %{
            name: "increment_counter",
            description: "Increment the internal counter",
            parameters: [
              %{name: "amount", type: :integer, required: true}
            ]
          }
        ]
      end
  """
  @callback list_capabilities() :: [map()]

  @optional_callbacks [list_capabilities: 0]
end
