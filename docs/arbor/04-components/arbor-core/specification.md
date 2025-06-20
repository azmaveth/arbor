# Arbor Core Application Specification

## Overview

The `arbor_core` application is the heart of the Arbor system. It implements the agent runtime, coordination, and orchestration logic. This is where agents are spawned, managed, and coordinated to accomplish tasks.

## Application Structure

```
apps/arbor_core/
├── lib/
│   └── arbor/
│       └── core/
│           ├── application.ex          # OTP Application supervisor
│           ├── agents/
│           │   ├── supervisor.ex       # Agent supervision strategies
│           │   ├── pool.ex            # Agent pool management
│           │   ├── base_agent.ex      # Base agent implementation
│           │   ├── tool_executor.ex   # Tool execution agent
│           │   ├── coordinator.ex     # Multi-agent coordinator
│           │   └── registry.ex        # Agent registry wrapper
│           ├── sessions/
│           │   ├── manager.ex         # Session lifecycle management
│           │   ├── session.ex         # Individual session process
│           │   └── state.ex           # Session state management
│           ├── tools/
│           │   ├── executor.ex        # Tool execution logic
│           │   ├── adapter.ex         # Tool adapter
│           │   └── safety.ex         # Tool safety checks
│           ├── messaging/
│           │   ├── router.ex          # Message routing
│           │   ├── bus.ex             # Internal message bus
│           │   └── dispatcher.ex     # Message dispatch logic
│           └── pubsub/
│               └── events.ex          # Event broadcasting
├── mix.exs
├── README.md
└── test/
```

## Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:arbor_contracts, in_umbrella: true},  # See [Core Contracts](../../03-contracts/core-contracts.md)
    {:arbor_security, in_umbrella: true},    # See [Security Specification](../arbor-security/specification.md)
    {:arbor_persistence, in_umbrella: true}, # See [State Persistence](../arbor-persistence/state-persistence.md)
    {:horde, "~> 0.8"},              # Distributed process management
    {:phoenix_pubsub, "~> 2.1"},     # Event broadcasting
    {:telemetry, "~> 1.0"},
    {:ex_mcp, path: "../../../ex_mcp"},  # Model Context Protocol client
    {:ex_llm, path: "../../../ex_llm"}   # LLM providers
  ]
end
```

## Core Modules

### Application Supervisor

```elixir
defmodule Arbor.Core.Application do
  @moduledoc """
  Main application supervisor for Arbor Core.
  """
  
  use Application
  
  @impl true
  def start(_type, _args) do
    children = [
      # Cluster management (Phase 2)
      {Horde.Registry, [name: Arbor.Core.Registry, keys: :unique]},
      {Horde.DynamicSupervisor, [
        name: Arbor.Core.AgentSupervisor,
        strategy: :one_for_one
      ]},
      
      # Core services
      {Phoenix.PubSub, name: Arbor.PubSub},
      Arbor.Core.Sessions.Manager,
      Arbor.Core.Agents.Pool,
      Arbor.Core.Messaging.Router,
      
      # Telemetry
      Arbor.Core.TelemetryReporter
    ]
    
    opts = [strategy: :one_for_one, name: Arbor.Core.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Base Agent Implementation

```elixir
defmodule Arbor.Core.Agents.BaseAgent do
  @moduledoc """
  Base implementation for all agents. Provides common functionality
  like state persistence, message handling, and capability management.
  """
  
  use GenServer
  require Logger
  
  @behaviour Arbor.Agent  # From arbor_contracts - see [Core Contracts](../../03-contracts/core-contracts.md)
  
  # Macro for defining agents
  defmacro __using__(opts) do
    quote do
      use GenServer
      @behaviour Arbor.Agent  # From arbor_contracts - see [Core Contracts](../../03-contracts/core-contracts.md)
      
      # Default implementations
      def init(args) do
        Arbor.Core.Agents.BaseAgent.init(__MODULE__, args)
      end
      
      def handle_cast({:message, envelope}, state) do
        Arbor.Core.Agents.BaseAgent.handle_message_wrapper(__MODULE__, envelope, state)
      end
      
      def handle_info({:capability_granted, capability}, state) do
        Arbor.Core.Agents.BaseAgent.handle_capability_wrapper(__MODULE__, capability, state)
      end
      
      def terminate(reason, state) do
        Arbor.Core.Agents.BaseAgent.terminate_wrapper(__MODULE__, reason, state)
      end
      
      # Allow overrides
      defoverridable [init: 1, terminate: 2]
    end
  end
  
  # Base implementation
  
  def init(module, args) do
    agent_id = args[:agent_id] || generate_agent_id()
    
    base_state = %{
      agent_id: agent_id,
      module: module,
      capabilities: MapSet.new(),
      metadata: args[:metadata] || %{},
      started_at: DateTime.utc_now()
    }
    
    # Register with discovery
    {:ok, _} = Arbor.Core.Agents.Registry.register(agent_id, self(), %{
      type: module,
      metadata: base_state.metadata
    })
    
    # Try to restore state
    # Uses arbor_persistence - see [State Persistence](../arbor-persistence/state-persistence.md)
    restored_state = case Arbor.Persistence.load_agent_state(agent_id) do
      {:ok, saved_state} ->
        Map.merge(base_state, saved_state)
      {:error, :not_found} ->
        base_state
    end
    
    # Let the implementing module initialize
    case module.init(args) do
      {:ok, custom_state} ->
        final_state = Map.merge(restored_state, %{custom: custom_state})
        
        # Emit telemetry
        :telemetry.execute(
          [:arbor, :agent, :start],
          %{count: 1},
          %{agent_id: agent_id, type: module}
        )
        
        {:ok, final_state}
        
      {:stop, reason} ->
        {:stop, reason}
    end
  end
  
  def handle_message_wrapper(module, envelope, state) do
    start_time = System.monotonic_time()
    
    # Validate sender capabilities if needed
    # ... validation logic ...
    
    result = module.handle_message(envelope, state.custom)
    
    # Update state and emit telemetry
    new_state = case result do
      {:noreply, new_custom} ->
        %{state | custom: new_custom}
        
      {:reply, reply, new_custom} ->
        send_reply(envelope, reply, state)
        %{state | custom: new_custom}
        
      {:stop, reason, new_custom} ->
        %{state | custom: new_custom}
    end
    
    duration = System.monotonic_time() - start_time
    :telemetry.execute(
      [:arbor, :agent, :message, :handled],
      %{duration: duration},
      %{agent_id: state.agent_id, message_type: envelope.payload.__struct__}
    )
    
    # Persist state changes
    persist_state_async(new_state)
    
    # Return appropriate GenServer response
    case result do
      {:noreply, _} -> {:noreply, new_state}
      {:reply, _, _} -> {:noreply, new_state}
      {:stop, reason, _} -> {:stop, reason, new_state}
    end
  end
  
  defp generate_agent_id do
    "agent_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
  
  defp persist_state_async(state) do
    Task.async(fn ->
      exportable = %{
        agent_id: state.agent_id,
        custom: state.module.export_state(state.custom),
        capabilities: MapSet.to_list(state.capabilities),
        metadata: state.metadata
      }
      
      Arbor.Persistence.save_agent_state(state.agent_id, exportable)  # Uses arbor_persistence
    end)
  end
end
```

### Session Manager

```elixir
defmodule Arbor.Core.Sessions.Manager do
  @moduledoc """
  Manages session lifecycle and provides session discovery.
  """
  
  use GenServer
  require Logger
  
  @table :mcp_sessions
  
  # Client API
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def create_session(opts \\ []) do
    GenServer.call(__MODULE__, {:create_session, opts})
  end
  
  def get_session(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, pid, metadata}] -> {:ok, pid, metadata}
      [] -> {:error, :not_found}
    end
  end
  
  def list_sessions do
    :ets.tab2list(@table)
    |> Enum.map(fn {id, pid, metadata} ->
      %{
        id: id,
        pid: pid,
        metadata: metadata,
        alive: Process.alive?(pid)
      }
    end)
  end
  
  # Server implementation
  
  @impl true
  def init(_opts) do
    # Create ETS table for fast lookups
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    
    # Subscribe to session events
    Phoenix.PubSub.subscribe(Arbor.PubSub, "sessions")
    
    {:ok, %{}}
  end
  
  @impl true
  def handle_call({:create_session, opts}, _from, state) do
    session_id = generate_session_id()
    
    # Start session under supervisor
    case Horde.DynamicSupervisor.start_child(
      Arbor.Core.AgentSupervisor,
      {Arbor.Core.Sessions.Session, 
        [
          session_id: session_id,
          created_by: opts[:created_by],
          metadata: opts[:metadata] || %{}
        ]
      }
    ) do
      {:ok, pid} ->
        # Store in ETS
        :ets.insert(@table, {session_id, pid, opts[:metadata] || %{}})
        
        # Monitor for cleanup
        Process.monitor(pid)
        
        # Broadcast event
        Phoenix.PubSub.broadcast(Arbor.PubSub, "sessions", {:session_created, session_id})
        
        Logger.info("Session created", session_id: session_id)
        {:reply, {:ok, session_id, pid}, state}
        
      {:error, reason} ->
        Logger.error("Failed to create session", reason: reason)
        {:reply, {:error, reason}, state}
    end
  end
  
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # Find and cleanup session
    case :ets.match_object(@table, {:_, pid, :_}) do
      [{session_id, ^pid, _}] ->
        :ets.delete(@table, session_id)
        Phoenix.PubSub.broadcast(Arbor.PubSub, "sessions", {:session_ended, session_id, reason})
        Logger.info("Session ended", session_id: session_id, reason: reason)
        
      [] ->
        # Not a session process
        :ok
    end
    
    {:noreply, state}
  end
  
  defp generate_session_id do
    "session_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
```

### Tool Executor Agent

```elixir
defmodule Arbor.Core.Agents.ToolExecutor do
  @moduledoc """
  Agent responsible for executing tools with proper security and isolation.
  """
  
  use Arbor.Core.Agents.BaseAgent
  
  alias Arbor.Security  # From arbor_security - see [Security Specification](../arbor-security/specification.md)
  alias Arbor.Core.Tools
  
  @impl Arbor.Agent
  def init(args) do
    state = %{
      session_id: args[:session_id],
      mcp_connections: %{},
      execution_history: []
    }
    
    {:ok, state}
  end
  
  @impl Arbor.Agent
  def handle_message(%Arbor.Messaging.Envelope{payload: {:execute_tool, tool_request}}, state) do
    result = execute_tool_safely(tool_request, state)
    
    new_state = %{state | 
      execution_history: [{tool_request, result, DateTime.utc_now()} | state.execution_history]
    }
    
    {:reply, result, new_state}
  end
  
  @impl Arbor.Agent
  def handle_capability(%Security.Capability{} = capability, state) do  # Capability struct from arbor_security
    # Store capability for later use
    {:ok, %{state | capabilities: [capability | state.capabilities]}}
  end
  
  @impl Arbor.Agent
  def export_state(state) do
    %{
      session_id: state.session_id,
      execution_history: Enum.take(state.execution_history, 100)  # Limit history
    }
  end
  
  @impl Arbor.Agent
  def import_state(persisted) do
    {:ok, %{
      session_id: persisted.session_id,
      mcp_connections: %{},
      execution_history: persisted.execution_history || []
    }}
  end
  
  # Private implementation
  
  defp execute_tool_safely(tool_request, state) do
    with {:ok, capability} <- find_capability_for_tool(tool_request, state),
         :ok <- Security.validate(capability, for_resource: tool_request.resource),  # From arbor_security
         {:ok, connection} <- ensure_mcp_connection(tool_request.server, state),
         {:ok, result} <- Tools.Executor.execute(connection, tool_request) do
      
      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.warning("Tool execution failed", 
          tool: tool_request.tool,
          reason: reason
        )
        error
    end
  end
  
  defp find_capability_for_tool(tool_request, state) do
    # Find a capability that grants access to this tool
    Enum.find_value(state.capabilities, {:error, :no_capability}, fn cap ->
      case Security.validate(cap, for_resource: build_tool_resource(tool_request)) do  # From arbor_security
        :ok -> {:ok, cap}
        _ -> nil
      end
    end)
  end
  
  defp build_tool_resource(tool_request) do
    {:tool, :execute, "#{tool_request.server}/#{tool_request.tool}"}
  end
end
```

### Agent Coordinator

```elixir
defmodule Arbor.Core.Agents.Coordinator do
  @moduledoc """
  Coordinates multiple agents to accomplish complex tasks.
  Implements the sub-agent spawning and delegation logic.
  """
  
  use Arbor.Core.Agents.BaseAgent
  
  alias Arbor.Security  # From arbor_security - see [Security Specification](../arbor-security/specification.md)
  alias Arbor.Core.Agents
  
  @impl Arbor.Agent
  def init(args) do
    state = %{
      task: args[:task],
      sub_agents: %{},        # agent_id => {pid, task, status}
      completed_tasks: [],
      strategy: args[:strategy] || :parallel
    }
    
    {:ok, state}
  end
  
  @impl Arbor.Agent
  def handle_message(%Arbor.Messaging.Envelope{payload: {:coordinate, task}}, state) do
    # Decompose task into subtasks
    subtasks = decompose_task(task)
    
    # Spawn sub-agents based on strategy
    new_state = case state.strategy do
      :parallel -> spawn_parallel_agents(subtasks, state)
      :sequential -> spawn_sequential_agents(subtasks, state)
      :adaptive -> spawn_adaptive_agents(subtasks, state)
    end
    
    {:noreply, new_state}
  end
  
  @impl Arbor.Agent
  def handle_message(%Arbor.Messaging.Envelope{payload: {:sub_agent_result, agent_id, result}}, state) do
    # Update sub-agent status
    new_state = update_sub_agent_status(agent_id, result, state)
    
    # Check if all done
    if all_agents_complete?(new_state) do
      aggregate_result = aggregate_results(new_state)
      {:reply, {:task_complete, aggregate_result}, new_state}
    else
      {:noreply, new_state}
    end
  end
  
  defp decompose_task(task) do
    # Task decomposition logic
    # This would be more sophisticated in practice
    case task.type do
      :code_review ->
        [
          %{type: :analyze_structure, target: task.target},
          %{type: :check_style, target: task.target},
          %{type: :find_bugs, target: task.target},
          %{type: :suggest_improvements, target: task.target}
        ]
        
      :data_processing ->
        # Split data into chunks
        task.data
        |> Enum.chunk_every(100)
        |> Enum.with_index()
        |> Enum.map(fn {chunk, idx} ->
          %{type: :process_chunk, data: chunk, index: idx}
        end)
        
      _ ->
        [task]  # Can't decompose, do it ourselves
    end
  end
  
  defp spawn_parallel_agents(subtasks, state) do
    new_agents = subtasks
    |> Enum.map(fn subtask ->
      # Spawn sub-agent
      {:ok, agent_id, pid} = Agents.Pool.spawn_agent(
        Arbor.Core.Agents.Worker,
        [
          parent_id: state.agent_id,
          task: subtask
        ]
      )
      
      # Delegate capabilities
      delegate_capabilities_to_agent(agent_id, subtask, state)
      
      {agent_id, {pid, subtask, :running}}
    end)
    |> Map.new()
    
    %{state | sub_agents: Map.merge(state.sub_agents, new_agents)}
  end
  
  defp delegate_capabilities_to_agent(agent_id, task, state) do
    # Determine what capabilities the sub-agent needs
    required_caps = analyze_required_capabilities(task)
    
    # Delegate subset of our capabilities
    Enum.each(required_caps, fn cap_type ->
      case find_capability(cap_type, state.capabilities) do
        {:ok, capability} ->
          constraints = build_constraints_for_task(task)
          Security.delegate(capability, agent_id, constraints)  # From arbor_security
          
        :error ->
          Logger.warning("Missing capability for delegation", 
            capability_type: cap_type,
            agent_id: agent_id
          )
      end
    end)
  end
  
  defp all_agents_complete?(state) do
    Enum.all?(state.sub_agents, fn {_id, {_pid, _task, status}} ->
      status in [:completed, :failed]
    end)
  end
end
```

### Message Router

```elixir
defmodule Arbor.Core.Messaging.Router do
  @moduledoc """
  Routes messages between agents based on addressing and capabilities.
  """
  
  use GenServer
  
  alias Arbor.Messaging.Envelope  # From arbor_contracts - see [Core Contracts](../../03-contracts/core-contracts.md)
  alias Arbor.Core.Agents.Registry
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def route(envelope) do
    GenServer.cast(__MODULE__, {:route, envelope})
  end
  
  @impl true
  def init(_opts) do
    {:ok, %{stats: %{routed: 0, failed: 0}}}
  end
  
  @impl true
  def handle_cast({:route, %Envelope{} = envelope}, state) do
    case route_message(envelope) do
      :ok ->
        {:noreply, update_stats(state, :routed)}
        
      {:error, reason} ->
        Logger.error("Failed to route message",
          to: envelope.to,
          from: envelope.from,
          reason: reason
        )
        {:noreply, update_stats(state, :failed)}
    end
  end
  
  defp route_message(%Envelope{to: "arbor://agent/" <> agent_id} = envelope) do
    case Registry.whereis(agent_id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:message, envelope})
        :ok
        
      :not_found ->
        {:error, :agent_not_found}
    end
  end
  
  defp route_message(%Envelope{to: "arbor://broadcast/" <> topic} = envelope) do
    Phoenix.PubSub.broadcast(Arbor.PubSub, topic, {:message, envelope})
    :ok
  end
  
  defp update_stats(state, type) do
    %{state | stats: Map.update!(state.stats, type, &(&1 + 1))}
  end
end
```

## Implementation Checklist

### Phase 1: Core Runtime
- [ ] Create application structure
- [ ] Implement base agent with state persistence
- [ ] Implement session manager
- [ ] Implement basic message routing
- [ ] Integrate with arbor_security for capabilities (See [Security Specification](../arbor-security/specification.md))
- [ ] Integrate with arbor_persistence for state (See [State Persistence](../arbor-persistence/state-persistence.md))
- [ ] Create tool executor agent
- [ ] Add telemetry throughout
- [ ] Write comprehensive tests

### Phase 2: Advanced Coordination
- [ ] Implement agent coordinator
- [ ] Add sub-agent spawning logic
- [ ] Implement different coordination strategies
- [ ] Add agent pool management
- [ ] Create specialized agent types
- [ ] Add dead letter handling

### Phase 3: Distribution
- [ ] Integrate Horde for distributed processes
- [ ] Implement cluster-aware routing
- [ ] Add split-brain resolution
- [ ] Create migration tools for rolling upgrades
- [ ] Add distributed tracing

## Testing Strategy

```elixir
defmodule Arbor.Core.AgentTest do
  use ExUnit.Case
  
  setup do
    # Start test supervision tree
    start_supervised!(Arbor.Core.TestSupervisor)
    :ok
  end
  
  test "agent lifecycle with state persistence" do
    # Spawn agent
    {:ok, agent_id, pid} = Arbor.Core.Agents.Pool.spawn_agent(
      TestAgent,
      [initial_value: 42]
    )
    
    # Send message
    envelope = %Arbor.Messaging.Envelope{
      to: "arbor://agent/#{agent_id}",
      from: "arbor://test",
      payload: {:increment, 8}
    }
    
    Arbor.Core.Messaging.Router.route(envelope)
    
    # Verify state changed
    assert {:ok, 50} = TestAgent.get_value(pid)
    
    # Kill agent
    Process.exit(pid, :kill)
    Process.sleep(100)
    
    # Verify restarted with persisted state
    {:ok, new_pid} = Arbor.Core.Agents.Registry.whereis(agent_id)
    assert new_pid != pid
    assert {:ok, 50} = TestAgent.get_value(new_pid)
  end
end
```