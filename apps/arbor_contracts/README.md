# Arbor Contracts

The contracts foundation for the Arbor distributed agent orchestration system. This application defines all shared data structures, behaviors, and schemas used throughout the system.

## Overview

`arbor_contracts` is a zero-dependency application that serves as the single source of truth for all contracts in the Arbor system. It provides:

- **Behaviors**: Contracts that all implementations must follow
- **Schemas**: Data structures with validation
- **Events**: Event definitions for event sourcing
- **Types**: Common type definitions and guards
- **Test Mocks**: Clearly labeled mock implementations for testing

## Contract Categories

### Core Contracts
- **Agent**: Behavior for all agents in the system
- **Message**: Inter-agent communication envelope
- **Capability**: Security capability tokens
- **Session**: Multi-agent coordination context

### Persistence Contracts
- **Store**: Event store behavior for event sourcing
- **Event**: Immutable event structure
- **Snapshot**: State snapshot for optimization

### Security Contracts
- **Enforcer**: Capability-based security enforcement
- **AuditEvent**: Security audit trail events

### Session Management
- **Manager**: Session lifecycle management
- **Session**: Enhanced session structure with state transitions

### Distributed Coordination
- **Registry**: Distributed process registry using Horde patterns
- **Supervisor**: Distributed supervision for fault tolerance

### Agent Coordination
- **Coordinator**: Inter-agent task delegation
- **Messages**: Structured messages for coordination

### Gateway Operations
- **API**: External client interface contract

## Usage

Add to your dependencies:

```elixir
{:arbor_contracts, in_umbrella: true}
```

### Implementing a Behavior

```elixir
defmodule MyAgent do
  @behaviour Arbor.Agent
  
  @impl true
  def init(args) do
    {:ok, %{state: args[:initial_state]}}
  end
  
  @impl true
  def handle_message(message, state) do
    # Process message
    {:noreply, state}
  end
  
  # Implement other callbacks...
end
```

### Using Schemas

```elixir
alias Arbor.Contracts.Core.Capability

# Create a capability
{:ok, cap} = Capability.new(
  resource_uri: "arbor://fs/read/docs",
  principal_id: "agent_123",
  expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
)

# Check validity
if Capability.valid?(cap) do
  # Use capability
end
```

### Working with Events

```elixir
alias Arbor.Contracts.Events.Event

# Create an event
{:ok, event} = Event.new(
  type: :agent_started,
  aggregate_id: "agent_123",
  data: %{
    agent_type: :llm,
    capabilities: [:read, :write]
  }
)

# Events are immutable and traceable
event.id          # Unique event ID
event.timestamp   # When it occurred
event.trace_id    # Distributed tracing
```

## Test Mocks

**WARNING**: Test mocks are clearly labeled and must NEVER be used in production!

```elixir
# In your test files only!
alias Arbor.Test.Mocks.InMemoryPersistence

setup do
  {:ok, store} = InMemoryPersistence.init([])
  {:ok, store: store}
end

test "event sourcing", %{store: store} do
  events = [%Event{type: :test_event, data: %{}}]
  {:ok, version} = InMemoryPersistence.append_events("stream", events, -1, store)
  assert version == 0
end
```

## Design Principles

1. **Zero Dependencies**: This app has NO dependencies on other umbrella apps
2. **Backwards Compatibility**: Changes require careful versioning
3. **Type Safety**: All contracts include typespec definitions
4. **Validation**: Built-in validation for data integrity
5. **Documentation**: Every contract is thoroughly documented

## Contract Stability

Once a contract is published and used, changing it requires:

1. Version bump in the `@version` module attribute
2. Migration strategy for existing implementations
3. Deprecation notices for removed functionality
4. Clear upgrade path documentation

## Development

### Adding a New Contract

1. Define the behavior in the appropriate namespace
2. Include comprehensive documentation
3. Add typespecs for all callbacks
4. Consider error cases and edge conditions
5. Add any required schemas or types

### Testing Contracts

Contracts themselves don't need testing, but you should:

1. Test your implementations against the contracts
2. Use property-based testing for contract compliance
3. Verify serialization/deserialization roundtrips
4. Test error conditions and validations

## Best Practices

1. **Keep Contracts Minimal**: Only include what's absolutely necessary
2. **Use Meaningful Types**: Create specific types rather than using `any()`
3. **Document Assumptions**: Make implicit assumptions explicit
4. **Version Everything**: Use `@version` attributes for tracking
5. **Think Long-term**: Contracts are hard to change once adopted

## Future Considerations

As the system evolves, we may add:

- Contract versioning and migration tools
- Runtime contract verification (using Norm)
- Contract compliance testing framework
- Automatic documentation generation
- Contract registry for discovery

## License

See the main Arbor project for license information.

