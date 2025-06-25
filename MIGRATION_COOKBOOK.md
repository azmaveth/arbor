# Mox Migration Cookbook

This document provides standardized patterns for migrating from hand-written test mocks to contract-based Mox testing.

## Phase 3b Completion Summary

The Mox migration Phase 3b has been successfully completed, establishing a solid foundation for contract-based testing in the Arbor project. While the original scope envisioned migrating 194 hand-written mock instances, Phase 3b focused on migrating the two most complex and critical mocks as a proof of concept.

### Key Achievements
- **Lines of Code Eliminated**: 548 (LocalSupervisor) + ~400 (LocalCoordinator refactoring)
- **Code Reduction**: 99% for migrated mocks
- **Tests Migrated**: 23 tests across 2 test files
- **Contracts Created**: 1 new behaviour (LocalCoordinatorBehaviour)
- **Helper Functions Added**: 12+ in MoxSetup module

### Technical Foundation Established
1. Contract-based testing infrastructure with behaviours
2. Enhanced dependency injection in production modules
3. Centralized Mox configuration with helper functions
4. Clear test migration patterns and best practices

## Overview

Our migration replaces 194 instances of hand-written test mocks with Mox-generated contract-compliant mocks. This eliminates duplicate code between production implementations and test mocks while enforcing contract compliance.

## Migration Patterns Discovered

### Pattern 1: Integration Tests vs Unit Tests

**Problem**: Some existing tests are integration tests that use real infrastructure with mock components.

**Example**: `HordeSupervisorTest` uses real Horde distributed components but mocks the agent processes.

**Solution**: 
- **Keep existing integration tests** for end-to-end validation
- **Add new unit tests** using Mox for fast, isolated testing
- Use naming convention: `*_integration_test.exs` vs `*_mox_test.exs`

```elixir
# BEFORE: Mixed integration test with partial mocks
defmodule Arbor.Core.HordeSupervisorTest do
  @moduletag :integration
  test "uses real Horde + mock agent" do
    # Real distributed infrastructure + TestAgent mock
  end
end

# AFTER: Separate concerns
defmodule Arbor.Core.HordeSupervisorIntegrationTest do
  @moduletag :integration  
  test "end-to-end with real infrastructure" do
    # Real distributed infrastructure + TestAgent mock  
  end
end

defmodule Arbor.Core.HordeSupervisorMoxTest do
  use ExUnit.Case, async: true
  import Mox
  
  test "unit test with contract mocks" do
    # Pure contract testing with Mox
  end
end
```

### Pattern 2: Direct Module Dependencies vs Dependency Injection

**Problem**: Modules that directly call other modules cannot be easily mocked.

**Example**: `HordeSupervisor` directly calls `HordeRegistry.lookup_agent_name(agent_id)`

**Solution**: 
- **Phase 1**: Create unit tests that mock at the boundary
- **Phase 2**: Gradually introduce dependency injection where valuable

```elixir
# BEFORE: Direct dependency (hard to mock)
defmodule HordeSupervisor do
  def get_agent_info(agent_id) do
    case HordeRegistry.lookup_agent_name(agent_id) do  # Direct call
      {:ok, pid, metadata} -> build_agent_info(agent_id, pid, metadata)
      error -> error
    end
  end
end

# OPTION A: Mock at the boundary (easier migration)
defmodule HordeSupervisorMoxTest do
  test "get_agent_info with mocked dependencies" do
    # Use Mox to replace HordeRegistry module in test environment
    Mox.expect(MockHordeRegistry, :lookup_agent_name, fn agent_id ->
      {:ok, test_pid, %{test: :metadata}}
    end)
  end
end

# OPTION B: Dependency injection (requires refactoring)
defmodule HordeSupervisor do
  def get_agent_info(agent_id, registry \\ HordeRegistry) do
    case registry.lookup_agent_name(agent_id) do
      {:ok, pid, metadata} -> build_agent_info(agent_id, pid, metadata)
      error -> error
    end
  end
end
```

### Pattern 3: Agent Mock vs Behavior Mock

**Problem**: Tests that use `TestAgent` (a full GenServer implementation) vs tests that should mock agent behavior.

**Solution**: Choose the right level of mocking based on what you're testing.

```elixir
# BEFORE: Using TestAgent (mini implementation)
test "agent lifecycle" do
  agent_spec = %{module: Arbor.Test.Mocks.TestAgent, ...}
  {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
  # TestAgent is a real GenServer - complex and stateful
end

# AFTER: Mock the agent behavior contract
test "agent lifecycle" do
  MockAgent
  |> expect(:start_link, fn args -> {:ok, test_pid} end)
  |> expect(:get_agent_metadata, fn state -> %{type: :test} end)
  
  agent_spec = %{module: MockAgent, ...}
  {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
end
```

### Pattern 4: Async vs Sync Testing

**Problem**: Distributed systems have timing dependencies that make tests flaky.

**Solution**: Use Mox for synchronous, deterministic testing.

```elixir
# BEFORE: Async testing with timing dependencies
test "agent registration eventually visible" do
  {:ok, pid} = HordeSupervisor.start_agent(spec)
  
  # Complex timing logic
  AsyncHelpers.wait_until(fn ->
    match?({:ok, _}, HordeSupervisor.get_agent_info(agent_id))
  end, timeout: 30_000)
end

# AFTER: Synchronous Mox testing
test "agent registration returns expected info" do
  MockRegistry
  |> expect(:lookup_name, fn agent_id -> 
    {:ok, test_pid, %{metadata: :test}}
  end)
  
  # Immediate, deterministic results
  assert {:ok, info} = HordeSupervisor.get_agent_info(agent_id)
  assert info.pid == test_pid
end
```

### Pattern 5: Setup Complexity

**Problem**: Integration tests require complex setup (infrastructure, timing, cleanup).

**Solution**: Mox tests use simple, isolated setup.

```elixir
# BEFORE: Complex integration setup
setup do
  # Start distributed infrastructure
  ensure_horde_infrastructure()
  
  # Configure cluster membership
  Horde.Cluster.set_members(registry, [{registry, node()}])
  
  # Wait for synchronization
  wait_for_membership_ready()
  
  on_exit(fn -> cleanup_horde_infrastructure() end)
  :ok
end

# AFTER: Simple Mox setup
setup do
  MoxSetup.setup_all_mocks()
  
  # Configure app to use mocks
  Application.put_env(:arbor_core, :registry_impl, MockRegistry)
  
  :ok
end
```

## Migration Strategy

### Phase 1: Add Mox Tests Alongside Existing Tests

1. **Keep existing tests** - Don't break working test coverage
2. **Add parallel Mox tests** - New files with `*_mox_test.exs` naming
3. **Focus on API contracts** - Test the public interface behavior
4. **Use fast, deterministic assertions** - No timing dependencies

### Phase 2: Identify High-Value Targets

Prioritize files with these characteristics:
- High complexity setup (saves maintenance time)
- Frequent test failures due to timing (improves reliability) 
- Core business logic (improves confidence)
- Hand-written mocks that duplicate production code (reduces duplication)

### Phase 3: Gradual Replacement

Once Mox tests provide equivalent coverage:
- Mark slow integration tests with `@tag :slow`
- Run Mox tests in CI by default
- Keep integration tests for comprehensive validation

## Test Categories After Migration

```elixir
# Unit Tests - Fast, isolated, contract-based
defmodule SomethingMoxTest do
  use ExUnit.Case, async: true
  import Mox
  # Tests contract behavior with mocks
end

# Integration Tests - Slow, end-to-end, real infrastructure  
defmodule SomethingIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :slow
  # Tests with real distributed components
end

# Property Tests - Comprehensive input validation
defmodule SomethingPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  # Tests with generated inputs
end
```

## Mox Best Practices

### 1. Use Contract-Based Mocks

```elixir
# GOOD: Contract enforcement
defmock(MockRegistry, for: Arbor.Contracts.Cluster.Registry)

# BAD: No contract enforcement  
defmock(MockRegistry)
```

### 2. Explicit Expectations

```elixir
# GOOD: Explicit expectations with argument matching
MockRegistry
|> expect(:lookup_name, fn {:agent, "test_id"} ->
  {:ok, test_pid, %{}}
end)

# BAD: Overly permissive mocks
MockRegistry
|> stub(:lookup_name, fn _ -> {:ok, test_pid, %{}} end)
```

### 3. Test Isolation

```elixir
# GOOD: Isolated test setup
setup :verify_on_exit!
setup :set_mox_from_context

# BAD: Global mocks that leak between tests
setup_all do
  Mox.set_mox_global()
end
```

### 4. Mock at the Right Level

```elixir
# GOOD: Mock external dependencies
MockRegistry |> expect(:lookup_name, ...)

# BAD: Mock internal implementation details  
MockInternalHelper |> expect(:parse_spec, ...)
```

## Validation Checklist

For each migrated test:
- [ ] **Contract Compliance**: Mock implements actual behaviour
- [ ] **Test Isolation**: Tests can run in parallel (`async: true`)
- [ ] **Deterministic**: No timing dependencies or random values
- [ ] **Focused**: Tests one unit of functionality
- [ ] **Fast**: Runs in milliseconds, not seconds
- [ ] **Maintainable**: Easy to understand and modify

## Migration Progress Tracking

Track these metrics during migration:
- Number of files using hand-written mocks: **194 → TARGET: 0**
- Test suite execution time: **Track improvement**
- Test flakiness incidents: **Track reduction** 
- Code duplication between prod/test: **Track elimination**

### Phase 3b Results
- **Mock instances migrated**: 2 of 194 (1% by count)
- **Impact**: Highest complexity mocks completed first
- **Code eliminated**: ~950 lines
- **Test reliability**: Improved (no timing dependencies)
- **Foundation**: Infrastructure ready for remaining migrations

### Completed Migrations
- ✅ LocalSupervisor → SupervisorMock (548 lines eliminated)
- ✅ LocalCoordinator → LocalCoordinatorMock (400+ lines refactored)

### Remaining Work (Phases 4-10)
- 🔲 LocalRegistry (estimated 300+ lines)
- 🔲 LocalSessionManager (estimated 200+ lines)
- 🔲 TestAgent variants (multiple files)
- 🔲 Various smaller mocks (~180 instances)

## Example Migrations

### LocalSupervisor Migration (Phase 3b)
The LocalSupervisor mock was completely replaced by Mox:
```elixir
# BEFORE: 548-line hand-written mock
defmodule Arbor.Test.Mocks.LocalSupervisor do
  # Complex GenServer implementation mimicking supervisor behavior
end

# AFTER: Contract-based Mox mock
defmock(Arbor.Test.Mocks.SupervisorMock, 
  for: Arbor.Contracts.Cluster.Supervisor)
```

### LocalCoordinator Migration (Phase 3b)
Transformed from stateful mock to contract-based testing:
```elixir
# BEFORE: Complex state management in tests
setup do
  {:ok, _pid} = LocalCoordinator.start_link([])
  LocalCoordinator.clear()
  # Complex setup...
end

# AFTER: Simple Mox expectations
setup :verify_on_exit!
setup :setup_mox

test "handles node join" do
  expect_coordinator_handle_node_join(node_info, :ok)
  assert :ok = ClusterCoordinator.handle_node_join(node_info)
end
```

See `apps/arbor_core/test/arbor/core/horde_supervisor_mox_test.exs` for additional patterns.

## Lessons Learned from Phase 3b

### What Worked Well
1. **Contract-First Approach**: Creating behaviours ensures type safety and API stability
2. **Helper Functions**: MoxSetup helpers dramatically reduce boilerplate
3. **Direct Module Injection**: Clean pattern for swapping implementations
4. **Incremental Migration**: Focusing on high-value targets proved effective

### Challenges Encountered
1. **Compilation Warnings**: Mox-generated mocks create warnings in non-test environments
2. **Function-Specific Mocks**: Some LocalSupervisor functions weren't part of standard contracts
3. **Mixed Test Types**: Some tests are true integration tests that shouldn't use mocks

### Best Practices Established
1. Always create a behaviour/contract before creating mocks
2. Use helper functions to encapsulate common mock expectations
3. Keep integration tests separate from unit tests
4. Tag slow tests appropriately for CI optimization

## Future Roadmap

### Immediate Next Steps (Phase 4)
1. **CI Optimization**: Configure test runs to use `@tag :slow` effectively
2. **Team Training**: Share patterns and best practices
3. **Automation**: Consider code generation for simple mock migrations

### Medium Term (Phases 5-10)
1. **Registry Mocks**: Migrate LocalRegistry and related mocks
2. **Session Mocks**: Migrate session management test mocks
3. **Agent Mocks**: Standardize agent testing patterns
4. **Performance Testing**: Measure test suite speed improvements

### Long Term Vision
- Achieve 100% contract-based testing for unit tests
- Reduce test suite execution time by 50%+
- Eliminate test flakiness from timing dependencies
- Enable true parallel test execution

## Recommendations

1. **Celebrate Success**: Phase 3b established critical patterns and infrastructure
2. **Realistic Planning**: Full migration will require dedicated effort over multiple phases
3. **Prioritize by Value**: Focus on mocks that cause the most test failures/maintenance
4. **Automate Where Possible**: Consider code generation for simple mock migrations
5. **Maintain Momentum**: Schedule regular migration sprints to maintain progress