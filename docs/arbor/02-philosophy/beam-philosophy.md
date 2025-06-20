# BEAM Philosophy and Contracts-First Design

## Overview

This document explores how Arbor's contracts-first architecture aligns with and enhances the traditional BEAM "let it crash" philosophy. Rather than being contradictory approaches, they are complementary tools for building robust distributed systems.

## The False Dichotomy

A common misconception is that "let it crash" and defensive programming are mutually exclusive. In reality, they serve different purposes and should be applied at different system boundaries.

### Core Distinction: Expected vs Unexpected Errors

The fundamental principle is understanding the difference between:

- **Expected Operational Errors**: Invalid data from external sources, network failures, user input errors
- **Unexpected System Errors**: Programming bugs, state corruption, impossible conditions

```elixir
# Expected error - validate and handle gracefully
def handle_api_request(params) do
  case Arbor.Contracts.Core.Capability.from_payload(params) do
    {:ok, capability} -> process_capability(capability)
    {:error, reason} -> {:error, :bad_request, reason}
  end
end

# Unexpected error - let it crash to reveal the bug
def process_capability(%Capability{id: id}) when is_binary(id) do
  # Pattern match enforces the contract
  # If id is not binary, this is a programmer error - crash with MatchError
  do_processing(id)
end
```

## BEAM Philosophy Principles

### 1. Code for the Happy Path

Focus on what your code should do in the successful case. Deal with unhappy paths only when necessary and appropriate.

**Contracts Enable Happy Path Programming:**
```elixir
# With contracts, internal code can assume valid data
def coordinate_agents(%Session{} = session, %Task{} = task) do
  # No need to check if session.id exists or task.type is valid
  # The contracts guarantee this data is well-formed
  agents = find_suitable_agents(session.capabilities, task.requirements)
  delegate_task(agents, task)
end
```

### 2. Process Isolation

All Elixir code runs in isolated processes. An unhandled exception in one process never crashes or corrupts another process.

**Contracts Protect Process Boundaries:**
```elixir
# Gateway validates before routing to agent processes
def handle_call({:execute_command, command_data}, _from, state) do
  case validate_command(command_data) do
    {:ok, command} ->
      # Safe to delegate to agent - data is validated
      agent_pid = spawn_agent_for_command(command)
      {:reply, {:async, execution_id}, state}
    
    {:error, reason} ->
      # Don't crash the gateway for bad input
      {:reply, {:error, reason}, state}
  end
end
```

### 3. Supervision and Recovery

Supervisors observe when processes terminate unexpectedly and restart them in a clean state.

**Contracts Reduce Supervisor Noise:**
- Without validation: Supervisors handle both real bugs AND bad data
- With validation: Supervisors only handle real bugs (high signal-to-noise ratio)

## Boundary Classification for Arbor

Different system boundaries require different validation strategies:

### External Untrusted Boundaries

**Examples**: Public APIs, client requests, external service responses
**Strategy**: Strict TypedStruct validation
**Rationale**: Highest risk; must protect system from malicious/malformed input

```elixir
def handle_client_request(json_payload) do
  case Jason.decode(json_payload) do
    {:ok, params} ->
      case Arbor.Contracts.Core.Message.from_payload(params) do
        {:ok, message} -> route_message(message)
        {:error, reason} -> {:error, :bad_request, reason}
      end
    {:error, _} -> {:error, :invalid_json}
  end
end
```

### External Trusted Boundaries  

**Examples**: Database state, configuration files, persistence layer
**Strategy**: Strict validation with migration support
**Rationale**: Data can be stale, legacy, or corrupted

```elixir
def restore_agent_state(agent_id) do
  case Persistence.load_state(agent_id) do
    {:ok, raw_state} ->
      # Validate and migrate legacy state
      case AgentState.from_persisted(raw_state) do
        {:ok, state} -> {:ok, state}
        {:error, :version_mismatch} -> migrate_and_validate(raw_state)
        {:error, reason} -> {:error, {:corrupt_state, reason}}
      end
    {:error, reason} -> {:error, reason}
  end
end
```

### Internal Semi-Trusted Boundaries

**Examples**: Agent-to-agent messages across network
**Strategy**: Strict validation for versioning compatibility
**Rationale**: Network unreliability; supports rolling deployments

```elixir
# Agent receives message from another agent
def handle_cast({:agent_message, payload}, state) do
  case Arbor.Contracts.Core.Message.from_payload(payload) do
    {:ok, message} ->
      # Process validated message
      new_state = process_agent_message(message, state)
      {:noreply, new_state}
    
    {:error, reason} ->
      # Log but don't crash - sender might be older version
      Logger.warn("Invalid agent message: #{inspect(reason)}")
      {:noreply, state}
  end
end
```

### Internal High-Trust Boundaries

**Examples**: Same-process function calls, internal module communication
**Strategy**: Pattern matching for contract enforcement
**Rationale**: Programmer contracts; crashes reveal bugs quickly

```elixir
# Internal function - let pattern matching enforce contracts
defp delegate_capability(%Capability{} = cap, %Agent{} = agent) do
  # Pattern match is our validation
  # If wrong types passed, MatchError points to the bug
  constrained_cap = apply_constraints(cap, agent.restrictions)
  grant_capability(agent.pid, constrained_cap)
end
```

## Validation Strategy Matrix

| Boundary Type | Validation Strategy | Error Handling | Arbor Examples |
|---------------|-------------------|----------------|----------------|
| **External Untrusted** | Strict TypedStruct | Return error response | Client API, external tools |
| **External Trusted** | Strict + Migration | Return error, log for ops | Persistence, configuration |
| **Internal Semi-Trusted** | Strict TypedStruct | Log warning, continue | Agent-to-agent messages |
| **Internal High-Trust** | Pattern matching | Let it crash | Intra-process calls |

## Benefits for Distributed Agent Orchestration

### 1. Network is the Ultimate Boundary

Every agent-to-agent message traverses a network boundary. Messages can be:
- Corrupted in transit
- From different versions during rolling deployment  
- Malformed due to bugs in sender
- Delayed or duplicated

Validation ensures agents remain stable regardless of network conditions.

### 2. Agent Independence

An agent receiving bad instructions from a peer shouldn't crash. It should reject the instruction with a clear error, allowing the orchestrator to handle the failure appropriately.

### 3. Version Evolution

TypedStruct with transformation pipelines enables zero-downtime deployments:

```elixir
def from_payload(payload) do
  payload
  |> upgrade_v1_to_v2()
  |> upgrade_v2_to_v3()
  |> new()
end
```

### 4. Clear Debugging

When agents do crash, it's a meaningful signal about real bugs, not noise from bad data. This makes debugging distributed systems much more tractable.

## Anti-Patterns to Avoid

### Over-Validation in High-Trust Code

```elixir
# BAD: Unnecessary validation in trusted internal code
defp process_internal_record(record) do
  if record != nil and Map.has_key?(record, :id) and is_binary(record.id) do
    # We already pattern matched on the struct type - this is redundant
    do_processing(record)
  else
    {:error, :invalid_record}
  end
end

# GOOD: Let pattern matching enforce the contract
defp process_internal_record(%InternalRecord{id: id} = record) when is_binary(id) do
  # Pattern match + guard is our contract
  # Wrong data type = MatchError = bug in caller
  do_processing(record)
end
```

### Under-Validation at Real Boundaries

```elixir
# BAD: Trusting external data without validation
def handle_external_api_response(json_response) do
  data = Jason.decode!(json_response)  # Could throw!
  user_id = data["user"]["id"]         # Could be nil!
  process_user(user_id)                # Could crash later!
end

# GOOD: Validate at the boundary
def handle_external_api_response(json_response) do
  case ExternalAPI.Response.from_json(json_response) do
    {:ok, %Response{user: %User{id: user_id}}} ->
      process_user(user_id)
    {:error, reason} ->
      {:error, {:invalid_response, reason}}
  end
end
```

## Testing Implications

### Contract Boundaries Enable Better Testing

```elixir
# Test the contract validation separately
test "rejects invalid capability payload" do
  invalid_payload = %{id: nil, resource_uri: "invalid"}
  assert {:error, _} = Capability.from_payload(invalid_payload)
end

# Test business logic with valid data (no need to test invalid shapes)
test "processes valid capability correctly" do
  capability = valid_capability_fixture()
  result = MyModule.process_capability(capability)
  assert {:ok, _} = result
end
```

### Property-Based Testing

TypedStruct integrates well with property-based testing:

```elixir
property "capability processing is idempotent" do
  check all capability <- valid_capability_generator() do
    result1 = process_capability(capability)
    result2 = process_capability(capability)
    assert result1 == result2
  end
end
```

## Performance Considerations

### Validation Overhead

- **Boundary validation**: Essential cost for system reliability
- **Internal validation**: Often unnecessary overhead
- **Hot path optimization**: Use plain structs for performance-critical internal data

### Compilation Benefits

TypedStruct generates Dialyzer types automatically, enabling static analysis to catch bugs before runtime.

## Conclusion

Arbor's contracts-first design is not defensive programming—it's **defensive architecture** that enables offensive (let-it-crash) programming where it matters most.

By validating expected errors at boundaries and letting unexpected errors crash cleanly, we achieve:

- **Resilient operation** under external pressure
- **Clear debugging signals** when real bugs occur
- **Graceful version evolution** across distributed deployments  
- **Production stability** that scales with system complexity

This approach follows established patterns in the Elixir ecosystem (Phoenix controllers, Ecto changesets, LiveView event handlers) and aligns perfectly with BEAM's supervision philosophy.

The key insight: **Use contracts to filter noise, use crashes to find signal.**

## Related Documents

- **[core-contracts.md](../03-contracts/core-contracts.md)**: Complete contract specifications
- **[architecture-overview.md](../01-overview/architecture-overview.md)**: System architecture
- **[schema-driven-design.md](../03-contracts/schema-driven-design.md)**: Validation strategy details