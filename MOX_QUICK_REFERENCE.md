# Mox Quick Reference Guide

## Setup

### 1. Add Mox to Your Test
```elixir
defmodule MyTest do
  use ExUnit.Case, async: true
  import Mox
  import Arbor.Test.Support.MoxSetup  # Our helpers
  
  setup :verify_on_exit!
  setup :setup_mox
end
```

### 2. Configure Module for Testing
```elixir
# In your module
defp get_impl do
  Application.get_env(:my_app, :impl, :auto)
end

# In test setup
Application.put_env(:my_app, :impl, MyMock)
```

## Common Patterns

### Basic Expectation
```elixir
expect(MockModule, :function_name, fn arg ->
  assert arg == expected_value
  {:ok, result}
end)
```

### Multiple Calls
```elixir
expect(MockModule, :function_name, 3, fn arg ->
  {:ok, result}
end)
```

### Stubbing (Use Sparingly)
```elixir
stub(MockModule, :function_name, fn _ ->
  {:ok, default_result}
end)
```

### Async Testing with Message Passing
```elixir
test "async operation" do
  test_pid = self()
  
  expect(MockModule, :async_function, fn arg ->
    send(test_pid, {:called, arg})
    :ok
  end)
  
  # Trigger async operation
  MyModule.do_async_thing()
  
  # Verify it was called
  assert_receive {:called, expected_arg}, 1000
end
```

## Helper Functions

### From MoxSetup
```elixir
# Supervisor helpers
expect_supervisor_start(agent_spec, {:ok, pid})
expect_supervisor_stop(agent_id, :ok)
expect_supervisor_get_info(agent_id, {:ok, info})

# Registry helpers  
expect_registry_register(name, pid, :ok)
expect_registry_lookup(name, {:ok, pid})
expect_registry_unregister(name, :ok)

# Coordinator helpers
expect_coordinator_handle_node_join(node_info, :ok)
expect_coordinator_get_cluster_info({:ok, cluster_info})
```

## Best Practices

### DO ✅
- Use expectations over stubs
- Verify specific arguments
- Use helpers for common patterns
- Test one behavior at a time
- Use `async: true` when possible

### DON'T ❌
- Create global stubs
- Use `stub_with/2` (usually)
- Mock internal functions
- Over-specify expectations
- Forget `verify_on_exit!`

## Debugging

### See All Expectations
```elixir
# In IEx during test
Mox.expectations_for(MockModule)
```

### Common Errors

**"No expectation defined"**
- You forgot to set an expectation
- The function was called more times than expected

**"Expected but not called"**
- Your code didn't reach the mocked function
- Wrong arguments were passed

**"Cannot add expectations/stubs"**
- You're not in test mode
- Mock not properly defined

## Migration Checklist

When migrating from hand-written mock:

1. [ ] Create behaviour for the mock's interface
2. [ ] Define mock in MoxSetup
3. [ ] Replace mock module with behaviour implementation
4. [ ] Convert stateful tests to expectations
5. [ ] Remove Process.sleep, use message passing
6. [ ] Delete old mock file
7. [ ] Run tests with `--trace` to verify

## Example Migration

### Before (Hand-written Mock)
```elixir
defmodule LocalRegistry do
  use GenServer
  
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def register(name, pid), do: GenServer.call(__MODULE__, {:register, name, pid})
  def lookup(name), do: GenServer.call(__MODULE__, {:lookup, name})
  
  # ... 100+ lines of GenServer callbacks
end

# In test
setup do
  {:ok, _} = LocalRegistry.start_link([])
  :ok
end

test "registers process" do
  :ok = LocalRegistry.register(:my_process, self())
  assert {:ok, pid} = LocalRegistry.lookup(:my_process)
end
```

### After (Mox)
```elixir
# Define behaviour
defmodule RegistryBehaviour do
  @callback register(atom(), pid()) :: :ok | {:error, term()}
  @callback lookup(atom()) :: {:ok, pid()} | {:error, :not_found}
end

# In MoxSetup
defmock(RegistryMock, for: RegistryBehaviour)

# In test
test "registers process" do
  my_pid = self()
  
  expect(RegistryMock, :register, fn :my_process, ^my_pid -> :ok end)
  expect(RegistryMock, :lookup, fn :my_process -> {:ok, my_pid} end)
  
  :ok = MyModule.register_self(:my_process)
  assert {:ok, ^my_pid} = MyModule.get_process(:my_process)
end
```

## Resources

- [Official Mox Documentation](https://hexdocs.pm/mox)
- [José Valim's Mox Article](https://dashbit.co/blog/mocks-and-explicit-contracts)
- Project: `MIGRATION_COOKBOOK.md`
- Project: `apps/arbor_core/test/support/mox_setup.ex`