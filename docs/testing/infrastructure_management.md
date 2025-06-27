# Integration Test Infrastructure Management

## Overview

This document describes the solution implemented to fix integration test failures caused by multiple test modules attempting to start the same global services (Horde components, distributed Erlang nodes, etc.).

## Problem

The original `IntegrationCase` implementation had each test module running its own `setup_all` callback, which attempted to start the same global services. This caused:

1. Race conditions when tests ran in parallel
2. "Already started" errors for Horde components
3. Conflicts in distributed Erlang node setup
4. No proper coordination between test modules

## Solution Architecture

### 1. Singleton Infrastructure Manager

Created `Arbor.Test.Support.InfrastructureManager` - a GenServer singleton that:

- Ensures infrastructure is started exactly once for the entire test suite
- Uses reference counting to track which test modules are using the infrastructure
- Provides idempotent operations for all infrastructure components
- Handles graceful cleanup when the last test module completes

Key features:
- Process monitoring for crash recovery
- Atomic setup operations
- Delayed cleanup to handle rapid test restarts
- Comprehensive error handling

### 2. Test Cleanup Module

Created `Arbor.Test.Support.TestCleanup` to:

- Clean up leftover processes from previous test runs
- Ensure a clean slate before starting tests
- Handle special cleanup requirements for different process types

### 3. Test Coordinator

Created `Arbor.Test.Support.TestCoordinator` providing:

- Unique test ID generation for namespace isolation
- Exclusive access locks for shared resources
- Retry mechanisms with exponential backoff
- Enhanced wait/assertion helpers

### 4. Updated IntegrationCase

Modified `IntegrationCase` to:

- Use the singleton InfrastructureManager
- Register/unregister test modules properly
- Provide test-specific namespacing
- Include better logging metadata

## Usage

### Basic Integration Test

```elixir
defmodule MyIntegrationTest do
  use Arbor.Test.Support.IntegrationCase
  
  test "my integration test" do
    # Infrastructure is automatically available
    # Use @test_namespace for unique identifiers
    agent_id = "test-agent-#{@test_namespace}"
    
    # Your test code here
  end
end
```

### Manual Infrastructure Management

```elixir
# Ensure infrastructure is started
:ok = InfrastructureManager.ensure_started()

# Register as a user (get cleanup function)
cleanup_fn = InfrastructureManager.register_user(MyModule)

# Do your work...

# Clean up when done
cleanup_fn.()
```

### Test Coordination Utilities

```elixir
# Generate unique test IDs
test_id = TestCoordinator.unique_test_id("agent")

# Execute with exclusive access
TestCoordinator.with_exclusive_access(:cluster_membership, fn ->
  # Modify cluster membership safely
end)

# Retry operations with backoff
TestCoordinator.retry_with_backoff("start agent", max_attempts: 3, fn ->
  HordeSupervisor.start_agent(spec)
end)
```

## Implementation Details

### Infrastructure Components Started

1. Distributed Erlang (if not already running)
2. Phoenix.PubSub
3. Task.Supervisor
4. Horde Supervisor and Registry
5. Horde Coordinator and Registry
6. Agent Reconciler
7. Cluster Manager
8. Sessions Manager
9. Gateway

### Startup Sequence

1. `test_helper.exs` loads support files and runs cleanup
2. First test module calls `InfrastructureManager.ensure_started()`
3. Infrastructure is started in a spawned process
4. All waiting test modules are notified when ready
5. Each test module registers its usage
6. Infrastructure persists across test modules
7. Cleanup happens after last module unregisters

### Error Handling

- Handles "already started" errors gracefully
- Reuses existing processes when appropriate
- Cleans up partial state before restarting
- Continues despite non-critical failures
- Provides detailed error reporting

## Benefits

1. **Reliability**: No more race conditions or startup conflicts
2. **Performance**: Infrastructure started once, not per test module
3. **Isolation**: Tests are properly isolated with namespacing
4. **Debugging**: Better error messages and logging metadata
5. **Flexibility**: Can run tests in parallel safely

## Troubleshooting

### Tests Still Failing

1. Check that `test_helper.exs` includes cleanup:
   ```elixir
   Arbor.Test.Support.TestCleanup.cleanup_all()
   ```

2. Verify infrastructure manager is loaded:
   ```elixir
   Code.require_file("support/infrastructure_manager.ex", __DIR__)
   ```

3. Check for leftover processes:
   ```elixir
   Process.whereis(Arbor.Core.HordeAgentRegistry)
   ```

### Manual Cleanup

If needed, manually clean up infrastructure:

```elixir
Arbor.Test.Support.TestCleanup.cleanup_all()
```

### Debugging Infrastructure State

```elixir
# Check if infrastructure is running
InfrastructureManager.infrastructure_running?()

# Check specific processes
Process.whereis(Arbor.Core.HordeAgentSupervisor)
```