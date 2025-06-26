# Arbor Test Infrastructure

This document provides a comprehensive guide to Arbor's test infrastructure, including utilities, patterns, and performance optimization strategies implemented across the umbrella project.

## Overview

Arbor's test infrastructure is designed for a distributed AI agent orchestration system built on Elixir/OTP. It provides comprehensive testing utilities for event sourcing, service integration, performance monitoring, and state consistency validation.

### Key Features

- **Smart Test Dispatching**: Tiered test execution with fast feedback loops
- **Event Sourcing Testing**: Specialized utilities for CQRS and event-driven patterns
- **Service Integration**: Cross-service boundary validation and contract testing
- **Performance Monitoring**: Real-time test performance tracking and optimization
- **State Consistency**: Distributed state validation across services
- **PostgreSQL Testcontainers**: Isolated database testing environments

## Test Architecture

### Test Hierarchy

```
test/
├── support/
│   ├── factories/               # Test data generation
│   ├── event_sourcing/         # Event sourcing utilities
│   ├── service_integration/    # Cross-service testing
│   ├── performance/           # Performance monitoring
│   └── testcontainers/        # Container management
├── unit/                      # Fast unit tests
├── integration/              # Service integration tests
├── distributed/             # Multi-node tests
└── chaos/                  # Chaos engineering tests
```

### Test Execution Tiers

Tests are organized into execution tiers for optimal feedback:

1. **Fast** (`@tag :fast`): Unit tests, mocks only (< 100ms each)
2. **Contract** (`@tag :contract`): Interface validation (< 500ms each)
3. **Integration** (`@tag :integration`): Service interactions (< 2s each)
4. **Distributed** (`@tag :distributed`): Multi-node scenarios (< 10s each)
5. **Chaos** (`@tag :chaos`): Failure injection and recovery (< 30s each)

## Test Utilities

### FastCase - Foundation Test Case

```elixir
defmodule MyTest do
  use Arbor.Persistence.FastCase
  
  test "unit test example" do
    stream_id = unique_stream_id("test")
    assert String.contains?(stream_id, "test")
  end
end
```

**Features:**
- Unique stream ID generation
- Fast execution (no external dependencies)
- Isolated test environment
- Basic factory support

### IntegrationCase - PostgreSQL Integration

```elixir
defmodule MyIntegrationTest do
  use Arbor.Persistence.IntegrationCase
  
  @moduletag :integration
  
  test "database integration" do
    # Testcontainer PostgreSQL available
    assert {:ok, _result} = EventStore.append_events(stream_id(), events)
  end
end
```

**Features:**
- PostgreSQL Testcontainer setup/teardown
- Database migration management
- Event store integration
- Transaction rollback between tests

### ServiceInteractionCase - Cross-Service Testing

```elixir
defmodule MyServiceTest do
  use Arbor.Test.ServiceInteractionCase
  
  test "gateway session workflow", %{interaction_context: ctx} do
    # Test complete cross-service workflow
    {:ok, session_id} = test_gateway_session_integration(ctx)
    
    # Validate service boundaries
    assert_state_consistency(ctx)
    
    # Check performance
    assert_performance_acceptable(ctx, :gateway_session_flow, 
      max_duration_ms: 1000, max_memory_mb: 5.0)
  end
end
```

**Features:**
- Service boundary validation
- Event propagation tracking
- Performance monitoring
- State consistency checking
- Error scenario testing

## Factory System

### StreamFactory - Event Stream Generation

```elixir
# Generate event streams
stream = StreamFactory.build(:user_session_stream, 
  session_id: "session_123",
  events: [:session_created, :agent_spawned, :command_executed]
)

# Custom stream patterns
stream = StreamFactory.build(:agent_lifecycle_stream,
  agent_id: "agent_456",
  working_dir: "/tmp/test"
)
```

### CommandFactory - Command Generation

```elixir
# Generate valid commands
command = CommandFactory.spawn_agent_command(
  agent_type: :llm,
  working_dir: "/tmp/test",
  metadata: %{session_id: "test_session"}
)

# Validate command structure
assert Command.validate(command) == :ok
```

### EventFactory - Event Generation

```elixir
# Generate domain events
events = EventFactory.build_list(3, :session_events, 
  session_id: "session_123"
)

# Custom event sequences
events = EventFactory.build_sequence(:agent_lifecycle_events,
  agent_id: "agent_456"
)
```

## Performance Monitoring

### TestPerformanceMonitor

```elixir
use Arbor.Test.Performance.TestPerformanceMonitor

test "performance sensitive operation", %{perf_monitor: monitor} do
  TestPerformanceMonitor.start_timing(monitor, :my_operation)
  
  # ... test code ...
  
  metrics = TestPerformanceMonitor.end_timing(monitor, :my_operation)
  assert metrics.duration_ms < 100
  assert metrics.memory_delta_mb < 1.0
end
```

**Metrics Tracked:**
- Execution duration (microsecond precision)
- Memory usage delta
- Process count changes
- Peak memory consumption
- Resource utilization

### Performance Validation

```elixir
# Set performance limits
limits = [
  max_duration_ms: 500,
  max_memory_mb: 10.0,
  max_process_count: 5
]

# Validate performance
assert :ok = TestPerformanceMonitor.validate_performance(monitor, limits)
```

## Service Integration Testing

### Service Boundary Validation

```elixir
# Track service calls
ServiceBoundaryValidator.track_call(validator, :gateway, :execute_command)
ServiceBoundaryValidator.track_call(validator, :session_manager, :create_session)

# Validate call sequence
assert ServiceBoundaryValidator.validate_call_sequence(validator, [
  {:gateway, :execute_command},
  {:session_manager, :create_session}
])

# Check for contract violations
assert :ok = ServiceBoundaryValidator.validate_contracts(validator)
```

### Event Propagation Tracking

```elixir
# Set event expectations
EventPropagationTracker.expect_event(tracker, :session_created, 5000)
EventPropagationTracker.expect_event(tracker, :agent_spawned, 5000)

# Record events
EventPropagationTracker.record_event(tracker, :session_created, %{}, "sessions:events")

# Validate expectations
assert :ok = EventPropagationTracker.validate_expectations(tracker)
```

### State Consistency Checking

```elixir
# Validate cross-service state
service_states = %{
  gateway: %{active_sessions: 2, active_executions: 1},
  session_manager: %{active_sessions: 2},
  registry: %{registered_agents: 2}
}

assert :ok = StateConsistencyChecker.validate_consistency(checker, service_states)

# Track resource lifecycle
StateConsistencyChecker.track_resource(checker, "agent_123", :agent, %{status: :starting})
StateConsistencyChecker.update_resource_state(checker, "agent_123", :registry, %{registered: true})
StateConsistencyChecker.untrack_resource(checker, "agent_123")
```

## PostgreSQL Testcontainers

### Container Management

```elixir
defmodule Arbor.Test.Testcontainers.PostgreSQLContainer do
  # Automatic container lifecycle
  def start_container(opts \\\\ []) do
    # Starts PostgreSQL in isolated container
    # Returns connection configuration
  end
  
  def stop_container(container_id) do
    # Clean container shutdown
  end
end
```

**Features:**
- Isolated PostgreSQL instances per test suite
- Automatic schema migration
- Connection pooling
- Resource cleanup
- Port management

### Integration with EventStore

```elixir
# Automatic setup in IntegrationCase
setup_all do
  {:ok, container} = PostgreSQLContainer.start_container()
  
  on_exit(fn ->
    PostgreSQLContainer.stop_container(container.container_id)
  end)
  
  %{postgres_config: container.config}
end
```

## Test Execution Commands

### Smart Test Dispatcher

```bash
# Run tests by tier
mix test --only fast                    # Unit tests only
mix test --only contract               # Contract tests
mix test --only integration           # Integration tests
mix test --only distributed          # Distributed tests
mix test --only chaos                # Chaos tests

# Combined execution
mix test --exclude slow               # Skip slow tests
mix test --include integration       # Include integration tests
```

### Performance Testing

```bash
# Run with performance monitoring
mix test --slowest 10                # Show 10 slowest tests
mix test.performance                 # Performance-focused test run
```

### Coverage and Quality

```bash
mix test --coverage                  # Generate coverage report
mix test.all                        # Full test suite with quality checks
mix quality                         # Code quality validation
```

## Performance Optimization Strategies

### Test Optimization Guidelines

1. **Use Appropriate Test Tiers**
   - Keep unit tests in `:fast` tier
   - Minimize `:integration` test count
   - Use mocks for external dependencies

2. **Database Optimization**
   - Use transactions for rollback
   - Minimize schema migrations
   - Pool database connections

3. **Service Testing**
   - Mock external service calls
   - Use in-memory implementations for tests
   - Validate contracts without full integration

4. **Memory Management**
   - Monitor memory usage in tests
   - Clean up processes and resources
   - Use lightweight test data

### Performance Monitoring

```elixir
# Monitor test suite performance
def measure_test_suite_performance do
  {time, _result} = :timer.tc(fn ->
    System.cmd("mix", ["test", "--only", "fast"])
  end)
  
  IO.puts("Fast test suite: #{time / 1000}ms")
end
```

## Best Practices

### Test Organization

1. **Follow Naming Conventions**
   ```elixir
   # Good
   test "gateway processes spawn_agent command successfully"
   test "session manager handles concurrent session creation"
   
   # Avoid
   test "test1"
   test "it works"
   ```

2. **Use Descriptive Tags**
   ```elixir
   @moduletag :integration
   @moduletag :gateway
   @tag :slow
   ```

3. **Structure Test Data**
   ```elixir
   # Use factories for consistency
   command = CommandFactory.spawn_agent_command(agent_type: :llm)
   
   # Avoid inline data
   command = %Command{type: :spawn_agent, ...}
   ```

### Error Testing

```elixir
test "handles service failures gracefully", %{interaction_context: ctx} do
  # Test error propagation
  result = test_error_propagation(ctx, :session_manager_failure)
  
  # Validate clean state after error
  assert :ok = StateConsistencyChecker.validate_clean_state(ctx.state_checker)
end
```

### Performance Testing

```elixir
test "service interaction performance", %{interaction_context: ctx} do
  # Measure operation
  {result, metrics} = PerformanceMonitor.measure_function(ctx.performance_monitor, :service_call, fn ->
    Gateway.execute_command(command, context, metadata)
  end)
  
  # Validate performance
  assert metrics.duration_ms < 100
  assert metrics.memory_delta_mb < 1.0
end
```

## Integration Patterns

### Gateway Testing

```elixir
test "gateway command execution workflow" do
  command = CommandFactory.spawn_agent_command()
  
  # Execute through gateway
  {:ok, execution_id} = Gateway.execute_command(command, %{
    user_id: "test_user",
    session_id: unique_stream_id("session")
  }, %{timestamp: DateTime.utc_now()})
  
  # Validate execution
  assert is_binary(execution_id)
end
```

### Event Sourcing Testing

```elixir
test "event store append and read" do
  stream_id = unique_stream_id("test_stream")
  events = EventFactory.build_list(3, :test_events)
  
  # Append events
  assert {:ok, _} = EventStore.append_events(stream_id, events)
  
  # Read events back
  assert {:ok, read_events} = EventStore.read_events(stream_id)
  assert length(read_events) == 3
end
```

### Session Management Testing

```elixir
test "session lifecycle management" do
  session_id = unique_stream_id("session")
  
  # Create session
  command = CommandFactory.create_session_command(session_id: session_id)
  assert {:ok, _} = Gateway.execute_command(command, context, metadata)
  
  # Validate session state
  assert {:ok, session} = SessionManager.get_session(session_id)
  assert session.status == :active
end
```

## Troubleshooting

### Common Issues

1. **Slow Test Execution**
   - Check for `:integration` tests without proper tagging
   - Verify database connection pooling
   - Monitor resource cleanup

2. **Flaky Tests**
   - Add proper test isolation
   - Use deterministic test data
   - Validate async operations with timeouts

3. **Memory Leaks**
   - Monitor process creation in tests
   - Ensure proper GenServer cleanup
   - Use TestPerformanceMonitor for detection

4. **Database Issues**
   - Verify Testcontainer health
   - Check migration status
   - Validate connection configuration

### Debugging Tools

```elixir
# Enable verbose test output
mix test --trace

# Run specific test with debugging
mix test test/path/to/test.exs:42 --trace

# Monitor system resources
:observer.start()
```

## Migration Guide

### Adopting the New Infrastructure

1. **Update Existing Tests**
   ```elixir
   # Before
   use ExUnit.Case
   
   # After
   use Arbor.Persistence.FastCase  # or IntegrationCase
   ```

2. **Add Performance Monitoring**
   ```elixir
   # Add to existing tests
   use Arbor.Test.Performance.TestPerformanceMonitor
   
   test "existing test", %{perf_monitor: monitor} do
     # ... existing test code ...
   end
   ```

3. **Replace Manual Data Creation**
   ```elixir
   # Before
   command = %Command{type: :spawn_agent, ...}
   
   # After
   command = CommandFactory.spawn_agent_command()
   ```

### Progressive Adoption

1. Start with `:fast` tier tests using `FastCase`
2. Add performance monitoring to critical tests
3. Migrate integration tests to `IntegrationCase`
4. Implement service interaction testing for complex workflows
5. Add chaos testing for critical failure scenarios

This infrastructure provides a solid foundation for testing Arbor's distributed architecture while maintaining fast feedback loops and comprehensive validation coverage.