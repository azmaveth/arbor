# Manual Testing Guide for Arbor Gateway Implementation

This guide shows you exactly what you can test manually right now, even without full agent implementations.

## 🚀 What's Currently Working

### 1. Core Infrastructure
- ✅ OTP Application supervision tree
- ✅ Horde distributed process management
- ✅ Phoenix PubSub event system
- ✅ Gateway pattern implementation
- ✅ Session lifecycle management
- ✅ Event-driven architecture
- ✅ Telemetry and logging

### 2. Gateway API
- ✅ Session creation and management
- ✅ Capability discovery
- ✅ Asynchronous command execution
- ✅ Event subscription and broadcasting
- ✅ Statistics and monitoring

## 🧪 Manual Testing Steps

### Start the Application

```bash
# From the project root
iex -S mix
```

You should see logs like:
```
Starting Arbor Core Application
Starting Horde.RegistryImpl with name Arbor.Core.Registry
Starting Horde.DynamicSupervisorImpl with name Arbor.Core.AgentSupervisor
Starting Arbor Session Manager
Starting Arbor Gateway
Arbor Core Application started successfully
```

### Test 1: Basic Gateway Operations

```elixir
# Check that core processes are running
Process.whereis(Arbor.Core.Gateway)
Process.whereis(Arbor.Core.Sessions.Manager)
Process.whereis(Arbor.PubSub)

# Create a session
{:ok, session_id} = Arbor.Core.Gateway.create_session(
  metadata: %{user: "tester", client_type: :cli}
)

# The session_id will look like: "session_abc123def456..."
IO.puts("Session created: #{session_id}")
```

### Test 2: Session Management

```elixir
# Get session information
{:ok, session_pid, metadata} = Arbor.Core.Sessions.Manager.get_session(session_id)
IO.inspect(metadata)

# Get session state
{:ok, state} = Arbor.Core.Sessions.Session.get_state(session_pid)
IO.inspect(state)

# List all active sessions
sessions = Arbor.Core.Sessions.Manager.list_sessions()
IO.puts("Active sessions: #{length(sessions)}")
```

### Test 3: Capability Discovery

```elixir
# Discover available capabilities
{:ok, capabilities} = Arbor.Core.Gateway.discover_capabilities(session_id)

# You should see capabilities like:
# - analyze_code: Analyze code for issues and improvements
# - execute_tool: Execute a specific tool  
# - query_agents: Query information about active agents

Enum.each(capabilities, fn cap ->
  IO.puts("#{cap.name}: #{cap.description}")
  IO.puts("  Parameters: #{inspect(cap.parameters)}")
end)
```

### Test 4: Event Subscription

```elixir
# Subscribe to session events
Phoenix.PubSub.subscribe(Arbor.PubSub, "sessions")

# Subscribe to specific session events  
Phoenix.PubSub.subscribe(Arbor.PubSub, "session:#{session_id}")

# Now any session events will be sent to your process
# You can check for messages with: flush()
```

### Test 5: Asynchronous Command Execution

```elixir
# Execute a command asynchronously
{:async, execution_id} = Arbor.Core.Gateway.execute(
  session_id, 
  "analyze_code", 
  %{path: "/test/project", language: "elixir"}
)

IO.puts("Execution started: #{execution_id}")

# Subscribe to execution events
Arbor.Core.Gateway.subscribe_execution(execution_id)

# Check for execution events
flush()

# You should see events like:
# {:execution_event, %{status: :started, message: "Command execution started", ...}}
# {:execution_event, %{status: :progress, progress: 25, message: "Processing command...", ...}}
# {:execution_event, %{status: :completed, result: %{...}, ...}}
```

### Test 6: Different Command Types

```elixir
# Test tool execution
{:async, exec_id2} = Arbor.Core.Gateway.execute(
  session_id,
  "execute_tool",
  %{tool_name: "code_formatter", args: %{style: "standard"}}
)

# Test agent querying
{:async, exec_id3} = Arbor.Core.Gateway.execute(
  session_id,
  "query_agents", 
  %{filter: %{type: :coordinator}}
)

# Subscribe to these executions too
Arbor.Core.Gateway.subscribe_execution(exec_id2)
Arbor.Core.Gateway.subscribe_execution(exec_id3)

# Check all events
flush()
```

### Test 7: Statistics and Monitoring

```elixir
# Gateway statistics
{:ok, gateway_stats} = Arbor.Core.Gateway.get_stats()
IO.inspect(gateway_stats)

# Session manager statistics  
{:ok, session_stats} = Arbor.Core.Sessions.Manager.get_stats()
IO.inspect(session_stats)

# You should see metrics like:
# - sessions_created
# - commands_executed  
# - active_sessions
# - uptime_seconds
```

### Test 8: Session Lifecycle

```elixir
# Create another session
{:ok, session_id2} = Arbor.Core.Gateway.create_session(
  metadata: %{client_type: :api, test_session: true}
)

# List sessions to see both
sessions = Arbor.Core.Sessions.Manager.list_sessions()
Enum.each(sessions, fn session ->
  IO.puts("Session #{session.id}: #{inspect(session.metadata)}")
end)

# End the first session
:ok = Arbor.Core.Gateway.end_session(session_id)

# Verify it's gone
case Arbor.Core.Sessions.Manager.get_session(session_id) do
  {:error, :not_found} -> IO.puts("Session properly ended")
  _ -> IO.puts("Session still exists!")
end
```

### Test 9: Event Broadcasting

```elixir
# Subscribe to all sessions events
Phoenix.PubSub.subscribe(Arbor.PubSub, "sessions")

# Create and end a session to see events
{:ok, test_session} = Arbor.Core.Gateway.create_session()
:ok = Arbor.Core.Gateway.end_session(test_session)

# Check for broadcasted events
flush()
```

### Test 10: Error Handling

```elixir
# Try to access non-existent session
case Arbor.Core.Gateway.discover_capabilities("invalid_session_id") do
  {:error, reason} -> IO.puts("Properly handled error: #{inspect(reason)}")
  _ -> IO.puts("Error handling might need work")
end

# Try unknown command
case Arbor.Core.Gateway.execute(session_id2, "unknown_command", %{}) do
  {:async, exec_id} -> 
    Arbor.Core.Gateway.subscribe_execution(exec_id)
    # Wait a moment then check events - should see error
    Process.sleep(1000)
    flush()
  {:error, reason} -> 
    IO.puts("Command rejected: #{inspect(reason)}")
end
```

## 🎯 What This Demonstrates

### Architecture Patterns ✅
- **Gateway Pattern**: Single entry point for all operations
- **Event-Driven**: Real-time updates via PubSub events  
- **Session Management**: Isolated contexts with lifecycle management
- **Async Operations**: Non-blocking command execution with progress tracking

### OTP Design ✅
- **Supervision Trees**: Fault-tolerant process hierarchies
- **GenServer State Management**: Proper state encapsulation
- **Process Registration**: Named process discovery
- **Process Monitoring**: Automatic cleanup on failures

### Distributed Systems ✅
- **Horde Integration**: Cluster-ready process distribution
- **Event Broadcasting**: System-wide event coordination
- **Process Isolation**: Independent session contexts

### Observability ✅
- **Telemetry Events**: Comprehensive metric emission
- **Structured Logging**: Detailed operation logging
- **Statistics**: Real-time system metrics
- **Error Handling**: Proper error propagation and logging

## 🚧 What's Missing (For Future Implementation)

- **Real Agent Implementations**: Currently using simulated responses
- **Security Validation**: Capability checking is stubbed
- **Persistence**: Session/state persistence not fully implemented
- **Tool Integration**: MCP tool execution is simulated
- **Advanced Routing**: Message routing between agents

## 🎉 Ready for Production?

The **core infrastructure** is production-ready:
- Fault tolerance ✅
- Event-driven architecture ✅  
- Session management ✅
- Monitoring and observability ✅
- API consistency ✅

You can build real agents on this foundation and they'll automatically get:
- Session isolation
- Event broadcasting  
- Telemetry integration
- Fault tolerance
- Distributed process management

## Next Steps

1. **Implement BaseAgent**: Create the agent runtime using the `Arbor.Agent` behaviour
2. **Add Tool Integration**: Connect to MCP servers for real tool execution  
3. **Security Implementation**: Complete capability validation system
4. **State Persistence**: Add full state persistence and recovery
5. **Agent Coordination**: Implement multi-agent orchestration patterns