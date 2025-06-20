# Gateway and Discovery Patterns for Arbor

## Overview

This document describes key architectural patterns adopted from the original MCP Chat command architecture that are essential for Arbor's distributed agent system. These patterns enable dynamic capability discovery, asynchronous operations, and multi-client support.

## Dynamic Capability Discovery

### Pattern Description

Rather than hard-coding available operations, Arbor agents advertise their capabilities dynamically. This creates a flexible, extensible system where new functionality can be added without client-side changes.

### Implementation

```elixir
defmodule Arbor.Agent.Capability do
  @typedoc "A capability that an agent can perform"
  @type t :: %__MODULE__{
    name: String.t(),
    description: String.t(),
    parameters: [parameter()],
    required_permissions: [Arbor.Contracts.Types.resource_uri()]
  }
  
  @type parameter :: %{
    name: String.t(),
    type: atom(),
    required: boolean(),
    description: String.t()
  }
end

defmodule Arbor.Agent.Behaviour do
  @callback list_capabilities() :: [Arbor.Agent.Capability.t()]
  @callback execute_capability(name :: String.t(), params :: map()) :: 
    {:ok, any()} | {:error, term()} | {:async, execution_id :: String.t()}
end
```

### Discovery Flow

1. Agent registers with Arbor.Core.Registry
2. Agent provides its capability list
3. Clients query the registry for available capabilities
4. Capabilities are filtered based on client's permissions

## Gateway Pattern

### Overview

The Gateway serves as the single entry point for all client interactions with the agent system. It handles:
- Authentication and authorization
- Capability discovery
- Async operation management
- Event routing

### Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   CLI       │     │   Web UI    │     │   API       │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │
       └───────────────────┴───────────────────┘
                           │
                    ┌──────▼──────┐
                    │   Gateway   │
                    └──────┬──────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
     ┌──────▼──────┐ ┌────▼────┐ ┌──────▼──────┐
     │   Agent A   │ │ Agent B │ │   Agent C   │
     └─────────────┘ └─────────┘ └─────────────┘
```

### Gateway Implementation

```elixir
defmodule Arbor.Core.Gateway do
  use GenServer
  
  alias Arbor.Core.{Registry, Sessions, Security}
  alias Arbor.Contracts.Types
  
  # Client API
  
  @spec discover_capabilities(session_id :: Types.session_id()) :: 
    {:ok, [capability_info()]} | {:error, term()}
  def discover_capabilities(session_id) do
    GenServer.call(__MODULE__, {:discover, session_id})
  end
  
  @spec execute(session_id :: Types.session_id(), command :: String.t(), params :: map()) ::
    {:ok, result :: any()} | 
    {:async, execution_id :: Types.execution_id()} |
    {:error, term()}
  def execute(session_id, command, params) do
    GenServer.call(__MODULE__, {:execute, session_id, command, params})
  end
  
  # Server callbacks
  
  def handle_call({:discover, session_id}, _from, state) do
    with {:ok, capabilities} <- get_authorized_capabilities(session_id) do
      {:reply, {:ok, capabilities}, state}
    end
  end
  
  def handle_call({:execute, session_id, command, params}, _from, state) do
    execution_id = Types.generate_execution_id()
    
    # Start async execution
    Task.Supervisor.async_nolink(Arbor.TaskSupervisor, fn ->
      execute_command(session_id, command, params, execution_id)
    end)
    
    {:reply, {:async, execution_id}, state}
  end
end
```

## Event-Driven Updates

### Pattern

All long-running operations publish progress events to a PubSub system. Clients subscribe to relevant topics and receive real-time updates.

### Event Schema

```elixir
defmodule Arbor.Events.Execution do
  use TypedStruct
  
  typedstruct do
    field :execution_id, String.t(), enforce: true
    field :session_id, String.t(), enforce: true
    field :agent_id, String.t(), enforce: true
    field :status, atom(), enforce: true  # :started, :progress, :completed, :failed
    field :progress, integer()  # 0-100
    field :message, String.t()
    field :result, any()  # Only for :completed status
    field :error, any()   # Only for :failed status
    field :timestamp, DateTime.t(), enforce: true
  end
end
```

### Event Flow

```elixir
# In an agent executing a task
defmodule Arbor.Agents.DataProcessor do
  def process_large_dataset(execution_id, dataset) do
    # Broadcast start event
    broadcast_event(execution_id, :started, "Processing dataset")
    
    dataset
    |> Stream.with_index()
    |> Stream.chunk_every(100)
    |> Enum.each(fn chunk ->
      # Process chunk
      process_chunk(chunk)
      
      # Broadcast progress
      progress = calculate_progress(chunk, dataset)
      broadcast_event(execution_id, :progress, "Processing...", progress)
    end)
    
    # Broadcast completion
    broadcast_event(execution_id, :completed, "Dataset processed", 100, result)
  end
  
  defp broadcast_event(execution_id, status, message, progress \\ nil, result \\ nil) do
    event = %Arbor.Events.Execution{
      execution_id: execution_id,
      session_id: get_session_id(),
      agent_id: self() |> inspect(),
      status: status,
      progress: progress,
      message: message,
      result: result,
      timestamp: DateTime.utc_now()
    }
    
    Phoenix.PubSub.broadcast(Arbor.PubSub, "execution:#{execution_id}", {:execution_event, event})
  end
end
```

### Client Subscription

```elixir
defmodule Arbor.Client.EventSubscriber do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(opts) do
    session_id = opts[:session_id]
    
    # Subscribe to session events
    Phoenix.PubSub.subscribe(Arbor.PubSub, "session:#{session_id}")
    
    {:ok, %{session_id: session_id, active_executions: %{}}}
  end
  
  def subscribe_to_execution(execution_id) do
    GenServer.cast(__MODULE__, {:subscribe, execution_id})
  end
  
  def handle_cast({:subscribe, execution_id}, state) do
    Phoenix.PubSub.subscribe(Arbor.PubSub, "execution:#{execution_id}")
    new_state = put_in(state.active_executions[execution_id], %{})
    {:noreply, new_state}
  end
  
  def handle_info({:execution_event, event}, state) do
    # Update UI or internal state based on event
    handle_execution_event(event, state)
    {:noreply, state}
  end
end
```

## Benefits for Arbor

1. **Extensibility**: New agents can be added without modifying clients
2. **Multi-Client Support**: All clients use the same Gateway and event system
3. **Resilience**: Clients can disconnect/reconnect without losing task state
4. **Security**: Capability-based discovery naturally enforces permissions
5. **Scalability**: Async operations prevent blocking; events enable real-time monitoring

## Implementation Phases

### Phase 1: Core Infrastructure
- Implement Gateway GenServer
- Define capability discovery protocol
- Set up PubSub for event distribution

### Phase 2: Agent Integration
- Update base agent to support capability listing
- Implement async execution pattern
- Add progress event broadcasting

### Phase 3: Client Support
- Create event subscriber for CLI client
- Implement WebSocket adapter for web clients
- Add execution resumption after disconnect

## Migration Considerations

For existing systems migrating to Arbor:
- Gateway can initially proxy to legacy systems
- Gradual migration of commands to capability-based model
- Event adapters can translate legacy responses to new event format