# The Dual Contract System

## Overview

Arbor employs a sophisticated dual-contract architecture that leverages two complementary mechanisms to ensure type safety, clear interfaces, and excellent testability. This approach combines the best of compile-time guarantees with runtime flexibility.

## The Two Contract Types

### 1. TypedStruct Contracts (Data Structures)

**Purpose**: Define the shape and constraints of data flowing through the system

**Location**: `apps/arbor_contracts/lib/arbor/contracts/core/`

**Use Cases**:
- Domain entities (Capability, Message, Session, Agent)
- Event definitions for event sourcing
- Configuration structures
- API request/response shapes

**Example**:
```elixir
defmodule Arbor.Contracts.Core.Capability do
  use TypedStruct
  
  @derive {Jason.Encoder, except: [:signature]}
  typedstruct enforce: true do
    field :id, Types.capability_id()
    field :resource_uri, Types.resource_uri()
    field :principal_id, Types.agent_id()
    field :granted_at, DateTime.t()
    field :expires_at, DateTime.t(), enforce: false
    field :delegation_depth, non_neg_integer(), default: 3
    field :constraints, map(), default: %{}
    field :metadata, map(), default: %{}
  end
end
```

### 2. Behavior Contracts (Interfaces)

**Purpose**: Define the functional interfaces that modules must implement

**Location**: `apps/arbor_contracts/lib/arbor/contracts/*/`

**Use Cases**:
- Service boundaries (Gateway, Supervisor, Registry)
- Plugin interfaces (Store, Tool, Client)
- Cross-application contracts
- Testable interfaces via Mox

**Example**:
```elixir
defmodule Arbor.Contracts.Cluster.Supervisor do
  @type agent_spec :: %{
    required(:id) => String.t(),
    required(:module) => module(),
    required(:args) => keyword()
  }
  
  @callback start_agent(agent_spec()) :: {:ok, pid()} | {:error, term()}
  @callback stop_agent(agent_id :: String.t()) :: :ok | {:error, term()}
  @callback list_agents() :: {:ok, [map()]} | {:error, term()}
end
```

## Implementation Pattern

### Step 1: Define the Contract

For data structures, create a TypedStruct:
```elixir
# apps/arbor_contracts/lib/arbor/contracts/core/my_entity.ex
defmodule Arbor.Contracts.Core.MyEntity do
  use TypedStruct
  
  typedstruct enforce: true do
    field :id, String.t()
    field :name, String.t()
    field :active, boolean(), default: true
  end
end
```

For interfaces, create a behavior:
```elixir
# apps/arbor_contracts/lib/arbor/contracts/services/my_service.ex
defmodule Arbor.Contracts.Services.MyService do
  @callback process(entity :: MyEntity.t()) :: {:ok, result} | {:error, reason}
  @callback validate(entity :: MyEntity.t()) :: :ok | {:error, reason}
end
```

### Step 2: Implement the Contract

```elixir
# apps/arbor_core/lib/arbor/core/my_service_impl.ex
defmodule Arbor.Core.MyServiceImpl do
  @behaviour Arbor.Contracts.Services.MyService
  
  alias Arbor.Contracts.Core.MyEntity
  
  @impl true
  def process(%MyEntity{} = entity) do
    # Implementation here
    {:ok, "processed"}
  end
  
  @impl true
  def validate(%MyEntity{active: false}), do: {:error, :inactive}
  def validate(%MyEntity{}), do: :ok
end
```

### Step 3: Test with Mox

```elixir
# test/support/mox_setup.ex
Mox.defmock(MyServiceMock, for: Arbor.Contracts.Services.MyService)

# test/my_feature_test.exs
defmodule MyFeatureTest do
  use ExUnit.Case, async: true
  
  import Mox
  
  test "processes active entities" do
    entity = %MyEntity{id: "123", name: "Test", active: true}
    
    MyServiceMock
    |> expect(:validate, fn ^entity -> :ok end)
    |> expect(:process, fn ^entity -> {:ok, "mocked result"} end)
    
    # Test code using the mock
  end
end
```

## Benefits of the Dual System

### 1. Compile-Time Safety
- TypedStruct catches field name typos
- Dialyzer validates type usage
- Behavior callbacks ensure interface compliance

### 2. Runtime Flexibility
- Optional runtime validation with Norm
- Pattern matching on struct types
- Clear error messages for contract violations

### 3. Testing Excellence
- Mox enforces contract compliance in tests
- 99% reduction in mock code compared to hand-written stubs
- Tests can only set expectations for actual contract functions

### 4. Documentation
- Contracts serve as living documentation
- @typedoc and @doc attributes provide inline help
- Clear separation of data and behavior

## When to Use Each Type

### Use TypedStruct When:
- Defining domain entities or value objects
- Creating event or message types
- Specifying configuration schemas
- Building API request/response structures

### Use Behaviors When:
- Defining service interfaces
- Creating plugin systems
- Establishing cross-application boundaries
- Building testable abstractions

### Use Both When:
- A service processes specific entity types
- You need both the data contract and the processing interface
- Building a complete bounded context

## Migration from Legacy Patterns

### From Plain Maps to TypedStruct
```elixir
# Before
def process_user(%{id: id, name: name} = user) do
  # Hope the map has the right keys
end

# After
def process_user(%User{id: id, name: name} = user) do
  # Compile-time guarantee of structure
end
```

### From Hand-Written Mocks to Mox
```elixir
# Before (548 lines of mock code)
defmodule LocalSupervisor do
  def start_agent(spec), do: {:ok, self()}
  # ... hundreds more lines
end

# After (2 lines)
Mox.defmock(SupervisorMock, for: Arbor.Contracts.Cluster.Supervisor)
# Configure in test as needed
```

## Best Practices

1. **Keep Contracts in arbor_contracts**: All contracts live in the zero-dependency app
2. **Use @impl true**: Always mark behavior callbacks with @impl true
3. **Document Contracts**: Use @moduledoc, @typedoc, and @doc liberally
4. **Validate at Boundaries**: Use TypedStruct validation when data enters the system
5. **Mock via Behaviors**: Never mock a concrete module, only behaviors

## Common Pitfalls

1. **Mixing Concerns**: Don't put behavior callbacks in TypedStruct modules
2. **Over-Mocking**: Only mock external dependencies, not internal modules
3. **Missing @behaviour**: Forgetting the behavior declaration breaks Mox
4. **Circular Dependencies**: Contracts must not depend on implementations

## Tooling Support

### Credo Checks (Coming Soon)
```elixir
# .credo.exs
{Arbor.Credo.Check.ContractEnforcement, []}
```

This will enforce:
- All public modules have behavior contracts
- All behaviors are defined in arbor_contracts
- All callbacks use @impl true

### Mix Tasks
```bash
# Generate a new behavior contract
mix arbor.gen.contract --behaviour MyService

# Generate Mox setup for a test
mix arbor.gen.mock test/my_test.exs
```

## Further Reading

- [Core Contracts](./core-contracts.md) - Detailed contract specifications
- [Schema-Driven Design](./schema-driven-design.md) - Validation strategies
- [Testing Strategy](../06-infrastructure/testing-strategy.md) - Mox patterns and practices
- [MIGRATION_COOKBOOK.md](/MIGRATION_COOKBOOK.md) - Mock migration patterns