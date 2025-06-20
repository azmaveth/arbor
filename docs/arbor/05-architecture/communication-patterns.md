# Native Agent Communication Patterns for Arbor

## Overview

This document describes high-performance, native BEAM communication patterns for Arbor's distributed agent system, inspired by the Native Filesystem Server pattern. The key insight is implementing a "dual-path" architecture that optimizes for both internal performance and external compatibility.

## Dual-Path Communication Architecture

### Pattern Description

Arbor agents use different communication pathways depending on whether the target is within the BEAM cluster or external:

1. **BEAM Native**: Direct BEAM message passing for all agents in the cluster (same-node or cross-node)
2. **External Protocol**: Serialized protocol (MCP, HTTP, etc.) for non-BEAM clients and servers

### Performance Characteristics

| Communication Type | Latency | Overhead | Use Case |
|-------------------|---------|----------|----------|
| Same-node BEAM calls | ~15μs | Minimal | Same-node agent coordination |
| Cross-node BEAM calls | ~100μs-1ms | Minimal | Cross-node agent coordination |
| External protocol | 1-5ms+ | Serialization + Network | Non-BEAM clients/servers |

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        Node A                                │
│  ┌─────────────┐  Same-node   ┌─────────────┐               │
│  │   Agent 1   │◄────────────►│   Agent 2   │               │
│  └─────────────┘   (~15μs)    └─────────────┘               │
│         │                             │                     │
│         │ Cross-node BEAM            │                     │
│         │   (~100μs-1ms)              │                     │
└─────────┼─────────────────────────────┼─────────────────────┘
          │                             │
          ▼                             ▼
┌─────────────────────────────────────────────────────────────┐
│              Distributed Erlang (BEAM Cluster)              │
└─────────────────────────────────────────────────────────────┘
          │                             │
          ▼                             ▼
┌─────────┴─────────────────────────────┴─────────────────────┐
│                        Node B                                │
│  ┌─────────────┐              ┌─────────────┐               │
│  │   Agent 3   │◄────────────►│   Agent 4   │               │
│  └─────────────┘              └─────────────┘               │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ External Protocol
                           │   (1-5ms+)
                           ▼
                ┌─────────────────────┐
                │   External Clients  │
                │  (Web, CLI, etc.)   │
                └─────────────────────┘
```

## Native Service Agents

### Concept

Specialized agents that manage node-local resources and expose fine-grained capabilities through both fast and standard paths.

### Implementation Pattern

```elixir
defmodule Arbor.Agents.NativeFileSystem do
  @moduledoc """
  Native filesystem service agent providing high-performance file operations
  for same-node agents with capability-based security.
  """
  
  use Arbor.Core.Agents.BaseAgent
  use Arbor.Agents.NativeService
  
  # Define available native functions
  @native_functions [
    %{name: "ls", description: "List directory contents", params: [:path]},
    %{name: "cat", description: "Read file contents", params: [:path]},
    %{name: "write", description: "Write to file", params: [:path, :content]},
    %{name: "mkdir", description: "Create directory", params: [:path]}
  ]
  
  # Native service behavior
  @impl Arbor.Agents.NativeService
  def list_native_functions, do: @native_functions
  
  @impl Arbor.Agents.NativeService
  def call_native_function("ls", %{"path" => path}, caller_capability) do
    with :ok <- validate_capability(caller_capability, :fs, :list, path),
         {:ok, entries} <- File.ls(path) do
      {:ok, entries}
    end
  end
  
  def call_native_function("cat", %{"path" => path}, caller_capability) do
    with :ok <- validate_capability(caller_capability, :fs, :read, path),
         {:ok, content} <- File.read(path) do
      {:ok, content}
    end
  end
  
  # Standard agent message handling for external clients
  @impl Arbor.Agent
  def handle_message(%Arbor.Messaging.Envelope{payload: {:execute_tool, tool_request}}, state) do
    # Standard, serialized path for external clients
    result = execute_tool_safely(tool_request, state)
    {:reply, result, state}
  end
  
  # Capability validation
  defp validate_capability(capability, resource_type, operation, path) do
    resource_uri = "arbor://#{resource_type}/#{operation}/#{path}"
    Arbor.Security.validate(capability, for_resource: {resource_type, operation, path})
  end
end
```

### Native Service Behavior

```elixir
defmodule Arbor.Agents.NativeService do
  @moduledoc """
  Behavior for agents that provide native, high-performance services
  to other agents on the same node.
  """
  
  @doc "List all native functions this service provides"
  @callback list_native_functions() :: [function_spec()]
  
  @doc "Execute a native function with capability validation"
  @callback call_native_function(
    function_name :: String.t(),
    params :: map(),
    caller_capability :: Arbor.Security.Capability.t()
  ) :: {:ok, result :: any()} | {:error, reason :: any()}
  
  @type function_spec :: %{
    name: String.t(),
    description: String.t(),
    params: [atom()],
    required_capabilities: [String.t()]
  }
  
  defmacro __using__(_opts) do
    quote do
      @behaviour Arbor.Agents.NativeService
      
      def native_call(function_name, params, caller_capability \\ nil) do
        __MODULE__.call_native_function(function_name, params, caller_capability)
      end
    end
  end
end
```

## Transport-Agnostic Communication Layer

### Router Implementation

```elixir
defmodule Arbor.Core.Communication.Router do
  @moduledoc """
  Routes agent communications through the optimal path based on
  target location and trust level.
  """
  
  alias Arbor.Core.{Registry, Security}
  
  @spec send_to_agent(
    from_agent_id :: String.t(),
    to_agent_id :: String.t(),
    message :: any(),
    opts :: keyword()
  ) :: {:ok, result :: any()} | {:async, execution_id :: String.t()} | {:error, reason :: any()}
  def send_to_agent(from_agent_id, to_agent_id, message, opts \\ []) do
    case determine_path(from_agent_id, to_agent_id) do
      {:native, target_pid} ->
        send_native(target_pid, message, opts)
        
      {:external, target_node} ->
        send_external(target_node, to_agent_id, message, opts)
        
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  # BEAM native messaging (same-node or cross-node)
  defp send_beam_native(target_pid, message, opts) do
    if opts[:async] do
      execution_id = generate_execution_id()
      Task.async(fn -> GenServer.call(target_pid, message) end)
      {:async, execution_id}
    else
      result = GenServer.call(target_pid, message)
      {:ok, result}
    end
  end
  
  # External protocol for non-BEAM clients/servers
  defp send_external_protocol(service_info, message, opts) do
    envelope = %Arbor.Messaging.Envelope{
      id: generate_message_id(),
      to: service_info.endpoint,
      from: "arbor://agent/#{from_agent_id}",
      payload: message,
      timestamp: DateTime.utc_now()
    }
    
    # Send via external protocol (HTTP, MCP, etc.)
    case service_info.protocol do
      :mcp -> Arbor.External.MCP.send_message(envelope)
      :http -> Arbor.External.HTTP.send_message(envelope)
      :grpc -> Arbor.External.GRPC.send_message(envelope)
    end
  end
  
  defp determine_path(from_agent_id, to_agent_id) do
    case Registry.lookup(to_agent_id) do
      {:ok, {pid, metadata}} ->
        # BEAM agent (same-node or cross-node) - use native BEAM messaging
        {:beam_native, pid}
        
      :not_found ->
        # Check if it's an external service
        case ExternalServices.lookup(to_agent_id) do
          {:ok, service_info} ->
            {:external_protocol, service_info}
          :not_found ->
            {:error, :agent_not_found}
        end
    end
  end
end
```

### Native Function Call Interface

```elixir
defmodule Arbor.Core.NativeCall do
  @moduledoc """
  High-performance interface for calling native functions on same-node agents.
  """
  
  @spec call(
    service_agent_id :: String.t(),
    function_name :: String.t(),
    params :: map(),
    caller_capability :: Arbor.Security.Capability.t()
  ) :: {:ok, result :: any()} | {:error, reason :: any()}
  def call(service_agent_id, function_name, params, caller_capability) do
    case Arbor.Core.Registry.lookup(service_agent_id) do
      {:ok, {pid, %{type: service_module}}} when node(pid) == node() ->
        # Verify this is a native service
        if function_exported?(service_module, :call_native_function, 3) do
          apply(service_module, :call_native_function, [function_name, params, caller_capability])
        else
          {:error, :not_native_service}
        end
        
      {:ok, {pid, _metadata}} ->
        {:error, :not_local_agent}
        
      :not_found ->
        {:error, :service_not_found}
    end
  end
  
  @spec list_functions(service_agent_id :: String.t()) :: {:ok, [function_spec()]} | {:error, reason :: any()}
  def list_functions(service_agent_id) do
    case Arbor.Core.Registry.lookup(service_agent_id) do
      {:ok, {pid, %{type: service_module}}} when node(pid) == node() ->
        if function_exported?(service_module, :list_native_functions, 0) do
          functions = apply(service_module, :list_native_functions, [])
          {:ok, functions}
        else
          {:error, :not_native_service}
        end
        
      _ ->
        {:error, :service_not_available}
    end
  end
end
```

## Resource Management Patterns

### Centralized Resource Agents

```elixir
defmodule Arbor.Agents.DatabasePool do
  @moduledoc """
  Centralized database connection pool for node-local agents.
  Provides native, high-performance database operations.
  """
  
  use Arbor.Core.Agents.BaseAgent
  use Arbor.Agents.NativeService
  
  @impl Arbor.Core.Agents.BaseAgent
  def init(args) do
    # Initialize connection pool
    pool_opts = [
      size: args[:pool_size] || 10,
      max_overflow: args[:max_overflow] || 5
    ]
    
    {:ok, pool} = Postgrex.start_link(pool_opts)
    
    {:ok, %{pool: pool}}
  end
  
  @impl Arbor.Agents.NativeService
  def list_native_functions do
    [
      %{name: "query", description: "Execute SQL query", params: [:sql, :params]},
      %{name: "transaction", description: "Execute in transaction", params: [:queries]}
    ]
  end
  
  @impl Arbor.Agents.NativeService
  def call_native_function("query", %{"sql" => sql, "params" => params}, capability) do
    with :ok <- validate_db_capability(capability, sql),
         {:ok, result} <- Postgrex.query(state.pool, sql, params) do
      {:ok, result.rows}
    end
  end
  
  defp validate_db_capability(capability, sql) do
    # Validate capability allows this SQL operation
    operation = determine_sql_operation(sql)
    resource_uri = "arbor://db/#{operation}/query"
    Arbor.Security.validate(capability, for_resource: {:db, operation, "query"})
  end
end
```

## Benefits for Arbor

### Performance Benefits
- **200-300x faster** for same-node agent communication
- **Zero serialization overhead** for native calls
- **Shared resource pools** reduce memory footprint
- **Zero-copy data transfer** for large datasets

### Architectural Benefits
- **Fault tolerance** through OTP supervision
- **Capability-based security** at function level
- **Transport transparency** - agents don't need to know communication path
- **Gradual optimization** - can start with standard path, optimize to native

### Security Benefits
- **Fine-grained capabilities** for native service functions
- **Trust boundary management** through capability validation
- **Resource isolation** through supervised agents
- **Audit trail** for both native and external calls

## Implementation Strategy

### Phase 1: Foundation
1. Implement `NativeService` behavior
2. Create transport-agnostic router
3. Build capability validation for native calls

### Phase 2: Core Services
1. Implement native filesystem agent
2. Add native database pool agent
3. Create native configuration service

### Phase 3: Optimization
1. Add performance monitoring
2. Implement automatic path optimization
3. Create native call caching layer

## Migration from External Services

For systems migrating from external MCP servers to native agents:

```elixir
defmodule Arbor.Migration.ExternalToNative do
  @doc """
  Gradual migration pattern that can serve from both external
  and native sources during transition.
  """
  def call_service(service_name, function_name, params, capability) do
    case try_native_call(service_name, function_name, params, capability) do
      {:ok, result} ->
        {:ok, result}
        
      {:error, :service_not_available} ->
        # Fallback to external service
        call_external_service(service_name, function_name, params, capability)
        
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

## Monitoring and Metrics

Track performance and usage patterns:

```elixir
defmodule Arbor.Metrics.NativeCalls do
  def record_call(service, function, duration, path_type) do
    :telemetry.execute(
      [:arbor, :native_call, :duration],
      %{duration: duration},
      %{service: service, function: function, path: path_type}
    )
  end
end
```

This pattern provides Arbor with a powerful foundation for high-performance agent coordination while maintaining compatibility with external systems and security requirements.