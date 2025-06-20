# Agent Restart Registration Solution

## Problem Summary

Agent restarts weren't being registered properly in the Arbor system. When `Horde.DynamicSupervisor` automatically restarted a crashed agent, the agent was not automatically re-registered in the `HordeRegistry`. This created "zombie" processes that were running but invisible to the rest of the system.

## Root Cause Analysis

The issue was in the agent lifecycle management architecture:

1. **Registration was coupled with manual starts**: Registration logic was in `HordeSupervisor.do_start_agent()`, which is only called for manual agent creation.

2. **Supervisor restarts bypassed registration**: When `Horde.DynamicSupervisor` restarted a crashed agent, it directly called the agent's `start_link` function, completely bypassing the `HordeSupervisor` and its registration logic.

3. **No self-registration pattern**: Agents didn't register themselves on startup, relying entirely on external registration.

## Solution Implemented

### 1. Self-Registration Pattern

**File**: `/Users/azmaveth/code/arbor/apps/arbor_core/lib/arbor/core/agent_behavior.ex`

Added a `register_self/2` helper function to `AgentBehavior` that agents can call in their `init/1` callback:

```elixir
def register_self(agent_id, metadata \\ %{}) do
  case Arbor.Core.HordeRegistry.register_name(agent_id, self(), metadata) do
    :ok ->
      Logger.info("Agent registered successfully", ...)
      :ok
    {:error, reason} = error ->
      Logger.error("Failed to register agent", ...)
      error
  end
end
```

### 2. Enhanced Agent Arguments

**File**: `/Users/azmaveth/code/arbor/apps/arbor_core/lib/arbor/core/horde_supervisor.ex`

Modified `do_start_agent/2` to pass agent identity in the startup arguments:

```elixir
enhanced_args = Keyword.merge(
  agent_spec.args,
  [
    agent_id: agent_id,
    agent_metadata: metadata.metadata,
    restart_strategy: metadata.restart_strategy
  ]
)

child_spec = %{
  id: agent_id,
  start: {agent_spec.module, :start_link, [enhanced_args]},
  restart: metadata.restart_strategy,
  type: :worker
}
```

### 3. Updated Agent Implementations

**File**: `/Users/azmaveth/code/arbor/apps/arbor_core/lib/arbor/test/mocks/test_agent.ex`

Updated test agents to use the self-registration pattern:

```elixir
@impl GenServer
def init(args) do
  # Extract agent identity from args
  agent_id = Keyword.get(args, :agent_id)
  agent_metadata = Keyword.get(args, :agent_metadata, %{})
  
  # Self-register with the registry
  if agent_id do
    case register_self(agent_id, agent_metadata) do
      :ok -> Logger.info("Agent registered successfully", ...)
      {:error, reason} -> Logger.error("Agent failed to register", ...)
    end
  end
  
  # Continue with normal initialization
  {:ok, state}
end
```

### 4. Improved Error Handling

**File**: `/Users/azmaveth/code/arbor/apps/arbor_core/lib/arbor/core/horde_supervisor.ex`

Enhanced `extract_agent_state_internal/1` to return proper error tuples:

```elixir
defp extract_agent_state_internal(pid) do
  try do
    case GenServer.call(pid, :extract_state, 5000) do
      state_data when is_map(state_data) -> {:ok, state_data}
      _ -> {:ok, %{}}
    end
  catch
    :exit, {:timeout, _} -> {:error, :extract_timeout}
    :exit, {:noproc, _} -> {:error, :process_not_found}
    kind, reason -> {:error, {:extract_failed, {kind, reason}}}
  end
end
```

### 5. Telemetry Monitoring

**File**: `/Users/azmaveth/code/arbor/apps/arbor_core/lib/arbor/core/horde_supervisor.ex`

Added telemetry event monitoring for supervisor events:

```elixir
defp monitor_supervisor_events() do
  :telemetry.attach_many(
    "arbor-horde-supervisor-events",
    [
      [:horde, :supervisor, :start_child],
      [:horde, :supervisor, :terminate_child],
      [:horde, :supervisor, :restart_child],
      [:horde, :supervisor, :shutdown]
    ],
    &handle_telemetry_event/4,
    nil
  )
end
```

## How It Works

### Normal Agent Start Flow

1. `HordeSupervisor.start_agent/1` is called
2. `do_start_agent/2` enhances args with `agent_id` and `agent_metadata`
3. `Horde.DynamicSupervisor.start_child/2` starts the agent
4. Agent's `init/1` calls `register_self/2` to register with `HordeRegistry`
5. `HordeSupervisor` verifies registration succeeded

### Restart Flow (Fixed)

1. Agent crashes due to error
2. `Horde.DynamicSupervisor` automatically restarts agent using child_spec
3. Agent's `init/1` extracts `agent_id` from args (still present from original start)
4. Agent calls `register_self/2` to re-register with `HordeRegistry`
5. Agent is now running and registered - no longer a "zombie"

## Benefits

1. **Automatic Re-registration**: Agents self-register on every start, including restarts
2. **Fault Tolerance**: No more "zombie" processes that are running but invisible
3. **Consistent Architecture**: Same registration logic for manual starts and restarts
4. **Better Observability**: Telemetry events for supervisor lifecycle
5. **Improved Error Handling**: Proper error propagation and logging

## Testing

Created comprehensive tests in:
- `/Users/azmaveth/code/arbor/apps/arbor_core/test/arbor/core/failover_test.exs` 
- `/Users/azmaveth/code/arbor/tmp/scripts/test_self_registration.exs`

The tests verify:
- Agents register correctly on start
- Agents re-register automatically after restart
- State extraction and restoration works properly
- Migration preserves state and registration

## Files Modified

1. **Agent Behavior** (`agent_behavior.ex`): Added self-registration helper
2. **Horde Supervisor** (`horde_supervisor.ex`): Enhanced args, improved error handling, telemetry
3. **Test Agent** (`test_agent.ex`): Implemented self-registration pattern
4. **Failover Tests** (`failover_test.exs`): Updated test agents to use new pattern

## Deployment Considerations

- **Backward Compatibility**: Existing agents without `agent_id` in args will continue to work
- **Registration Timing**: Brief sleep in supervisor to ensure registration completes
- **Error Recovery**: Agents that fail to register will be terminated by supervisor
- **Logging**: Comprehensive logging for debugging registration issues

## Future Improvements

1. **Distributed Timers**: Implement TTL functionality for agent registrations
2. **Health Monitoring**: Use telemetry events for cluster health dashboards
3. **Load Balancing**: Improve agent distribution across cluster nodes
4. **State Persistence**: Consider external state storage for critical agents

This solution ensures that agent restarts are properly handled and agents remain discoverable and accessible after being restarted by the Horde supervisor.