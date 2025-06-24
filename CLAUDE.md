# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Arbor is a distributed AI agent orchestration system built on Elixir/OTP, designed for fault-tolerance, scalability, and security. It uses an umbrella project structure with capability-based security, event sourcing, and CQRS patterns.

## Development Commands

### Essential Commands
```bash
# Initial setup (run once)
./scripts/setup.sh

# Start development server
./scripts/dev.sh

# Run tests (various options)
./scripts/test.sh              # Full test suite
./scripts/test.sh --fast        # Skip dialyzer for quick feedback
./scripts/test.sh --coverage    # Generate coverage report
mix test test/path/to/test.exs  # Run specific test file

# Connect to running node
./scripts/console.sh

# Code quality checks
mix format                      # Format code
mix format --check-formatted    # Check formatting
mix credo --strict              # Static analysis
mix dialyzer                    # Type checking
mix quality                     # Run all quality checks

# Documentation
mix docs                        # Generate API documentation

# Benchmarking
./scripts/benchmark.sh          # Run performance benchmarks

# Build release
./scripts/release.sh            # Build production release
```

### Mix Aliases
- `mix setup` - Initial setup (deps.get, deps.compile, compile)
- `mix test.all` - Full test suite with coverage, credo, and dialyzer
- `mix test.ci` - CI-specific test suite
- `mix quality` - Code quality checks (format, credo, dialyzer)

## Architecture Overview

### Umbrella Applications

The project consists of four applications with strict dependency hierarchy:

1. **arbor_contracts** (zero dependencies)
   - Foundation layer with schemas, types, and protocols
   - All data structures and interfaces are defined here
   - Path: `apps/arbor_contracts/`

2. **arbor_security** (depends on: arbor_contracts)
   - Capability-based security system
   - Authentication, authorization, and audit logging
   - Path: `apps/arbor_security/`

3. **arbor_persistence** (depends on: arbor_contracts)
   - Event sourcing and CQRS implementation
   - State management and recovery
   - Path: `apps/arbor_persistence/`

4. **arbor_core** (depends on: all above)
   - Main business logic and agent orchestration
   - Session management and task distribution
   - Uses Horde for distributed process management
   - Path: `apps/arbor_core/`

### Key Design Patterns

1. **Gateway Pattern**: Core application uses gateways to interact with other apps
2. **Event Sourcing**: All state changes are captured as immutable events
3. **CQRS**: Separate read and write models for performance
4. **Capability-Based Security**: Fine-grained permissions with automatic expiration
5. **Supervision Trees**: Fault-tolerant architecture using OTP supervisors

### Important Modules

- `Arbor.Core.Gateway` - Central gateway for cross-app communication
- `Arbor.Security.CapabilityKernel` - Core security capability management
- `Arbor.Persistence.EventStore` - Event storage and retrieval
- `Arbor.Core.AgentSupervisor` - Agent lifecycle management

## Development Workflow

### Pre-commit Hooks
The project has Git pre-commit hooks that automatically run:
1. Code formatting check (`mix format --check-formatted`)
2. Static analysis (`mix credo --strict`) 
3. Type checking (`mix dialyzer`)
4. Unit tests (`mix test`)

To run these checks manually before committing:
```bash
mix format
mix credo --strict
mix dialyzer
mix test
```

### Testing Patterns
- Unit tests with mocks for isolated testing
- Integration tests marked with `@tag :integration`
- Property-based tests using ExUnitProperties
- Test coverage target: ≥80%

### Common Development Tasks

#### Running a single test
```bash
mix test test/arbor/core/agent_test.exs
mix test test/arbor/core/agent_test.exs:42  # Run test at specific line
```

#### Running tests by tag
```bash
mix test --only integration
mix test --only property
mix test --exclude slow
```

#### Connecting to distributed node
```bash
# In one terminal
./scripts/dev.sh

# In another terminal
./scripts/console.sh
```

## Distributed Development

The development environment runs as a distributed Erlang node:
- Node name: `arbor@localhost`
- Cookie: `arbor_dev`

This allows testing distributed features locally and connecting multiple console sessions.

## Configuration

- Base config: `config/config.exs`
- Development: `config/dev.exs` (if exists)
- Test: `config/test.exs` (if exists)
- Production: `config/prod.exs` (if exists)

## Code Conventions

1. Follow existing module structure and naming patterns
2. Use contracts from `arbor_contracts` for all data structures
3. Implement proper error handling with tagged tuples (`{:ok, result}` / `{:error, reason}`)
4. Add type specs for all public functions
5. Use meaningful Logger metadata for tracing
6. Write tests before implementation (TDD approach)

## Common Pitfalls

1. **Circular Dependencies**: Apps must follow the dependency hierarchy
2. **Direct Cross-App Calls**: Use the gateway pattern in arbor_core
3. **Missing Type Specs**: All public functions need `@spec` annotations
4. **Skipping Pre-commit**: Always let pre-commit hooks run (don't use --no-verify)

## Observability

The project includes comprehensive observability:
- Metrics via Telemetry/Prometheus
- Structured logging with correlation IDs
- Distributed tracing with OpenTelemetry
- Pre-configured Grafana dashboards (when using docker-compose)

## Performance Considerations

1. Event streams can grow large - use projections for queries
2. Capability checks happen frequently - keep them efficient
3. Use process pooling for resource-intensive operations
4. Monitor memory usage in long-running agents

## Contract-First Architecture System

Arbor enforces a **contract-first architecture** using automated guardrails to ensure all implementations follow defined interfaces and maintain architectural consistency across the distributed system.

### When Contracts Are Required

**MANDATORY** - You must create or use contracts for:

1. **Core System Components**
   - Any module ending with `Supervisor`, `Registry`, `Gateway`, `Manager`, `Coordinator`
   - All modules in `apps/arbor_core/lib/arbor/core/`
   - All cross-application interfaces and protocols

2. **Distributed Process Management**
   - Agent behaviors and lifecycle management
   - Cluster coordination and node communication
   - Session management and state handling

3. **External Interface Boundaries**
   - CLI command definitions and routing
   - API endpoints and message handling
   - Client-server communication protocols

4. **Data Structure Definitions**
   - Event schemas for event sourcing
   - Capability and security models
   - Configuration and state structures

### Contract Creation Workflow

#### Step 1: Design the Contract
```bash
# 1. Create contract in arbor_contracts first
# Location: apps/arbor_contracts/lib/arbor/contracts/[domain]/[name].ex

# Example contract structure:
defmodule Arbor.Contracts.Cluster.Supervisor do
  @moduledoc """
  Contract for distributed supervisor implementations.
  """
  
  @callback start_agent(spec :: map()) :: {:ok, pid()} | {:error, term()}
  @callback stop_agent(agent_id :: binary()) :: :ok | {:error, term()}
  @callback restart_agent(agent_id :: binary()) :: {:ok, pid()} | {:error, term()}
  @callback list_agents() :: {:ok, [map()]} | {:error, term()}
end
```

#### Step 2: Generate Implementation Scaffold
```bash
# 2. Use the Mix generator to create implementation
mix arbor.gen.impl Arbor.Contracts.Cluster.Supervisor Arbor.Core.HordeSupervisor

# This creates: apps/arbor_core/lib/arbor/core/horde_supervisor.ex
# With proper @behaviour declarations and callback stubs
```

#### Step 3: Implement the Callbacks
```elixir
defmodule Arbor.Core.HordeSupervisor do
  @behaviour Arbor.Contracts.Cluster.Supervisor
  
  @impl true
  def start_agent(spec) do
    # Your implementation here
  end
  
  @impl true
  def stop_agent(agent_id) do
    # Your implementation here
  end
  
  # ... implement all callbacks
end
```

### Contract Scaffolding Tool

The `mix arbor.gen.impl` command automatically generates compliant implementations:

```bash
# Generate implementation for any contract
mix arbor.gen.impl <ContractModule> <ImplementationModule>

# Examples:
mix arbor.gen.impl Arbor.Contracts.Gateway.API Arbor.Core.Gateway
mix arbor.gen.impl Arbor.Contracts.Session.Manager Arbor.Core.Sessions.Manager
mix arbor.gen.impl Arbor.Contracts.Agents.Coordinator Arbor.Core.AgentCoordinator
```

**Generated files include:**
- Proper `@behaviour` declarations
- All required callback function stubs with `@impl true`
- Documentation templates and TODOs
- Correct file placement based on module namespace

### File Placement Rules

The scaffolding system automatically places files in the correct umbrella application:

| Module Namespace | Target Location | Application |
|------------------|-----------------|-------------|
| `Arbor.Core.*` | `apps/arbor_core/lib/arbor/core/` | arbor_core |
| `Arbor.Security.*` | `apps/arbor_security/lib/arbor/security/` | arbor_security |
| `Arbor.Persistence.*` | `apps/arbor_persistence/lib/arbor/persistence/` | arbor_persistence |
| `Arbor.Contracts.*` | `apps/arbor_contracts/lib/arbor/contracts/` | arbor_contracts |

### Contract Validation

The system includes multiple validation layers:

1. **Compile-Time Enforcement**
   - Dialyzer type checking ensures callback compliance
   - `@behaviour` declarations enforce interface contracts

2. **Static Analysis** (Custom Credo Check)
   - Automatically detects missing `@behaviour` declarations
   - Suggests appropriate contract modules
   - Enforces architectural patterns

3. **Pre-commit Validation**
   - All commits automatically validated for contract compliance
   - Prevents architectural drift and missing declarations

### Example: Creating a New Agent Type

```bash
# 1. Create the agent contract
# File: apps/arbor_contracts/lib/arbor/contracts/agents/task_agent.ex
defmodule Arbor.Contracts.Agents.TaskAgent do
  @callback execute_task(task :: map()) :: {:ok, result :: any()} | {:error, term()}
  @callback get_progress() :: {:ok, percentage :: float()} | {:error, term()}
end

# 2. Generate the implementation
mix arbor.gen.impl Arbor.Contracts.Agents.TaskAgent Arbor.Core.TaskAgent

# 3. Implement the callbacks in the generated file
# File: apps/arbor_core/lib/arbor/core/task_agent.ex (auto-generated)
```

### Contract Documentation Standards

All contracts must include:

```elixir
defmodule Arbor.Contracts.Example.Service do
  @moduledoc """
  Contract for [specific domain] services.
  
  This contract defines the interface for [description of responsibility].
  Implementations must handle [key requirements and constraints].
  """
  
  @typedoc "Configuration options for the service"
  @type config :: map()
  
  @typedoc "Service execution result"
  @type result :: {:ok, term()} | {:error, term()}
  
  @doc """
  Starts the service with the given configuration.
  
  ## Parameters
  - `config`: Service configuration map
  
  ## Returns
  - `{:ok, pid}` - Service started successfully
  - `{:error, reason}` - Service failed to start
  """
  @callback start_service(config()) :: {:ok, pid()} | {:error, term()}
end
```

### Migration Guide for Existing Code

When adding contracts to existing modules:

1. **Identify the Contract**: Determine which contract the module should implement
2. **Add @behaviour Declaration**: Add `@behaviour ContractModule` to the top of the module
3. **Add @impl Annotations**: Mark all callback implementations with `@impl true`
4. **Verify Compliance**: Run `mix credo --strict` to check for issues

### Common Contract Patterns

**Supervisor Pattern:**
```elixir
@callback start_child(spec) :: {:ok, pid()} | {:error, term()}
@callback terminate_child(id) :: :ok | {:error, term()}
@callback which_children() :: [{id, pid(), type, modules}]
```

**Registry Pattern:**
```elixir
@callback register_name(name, pid) :: :yes | :no
@callback unregister_name(name) :: :ok
@callback whereis_name(name) :: pid() | :undefined
```

**Gateway Pattern:**
```elixir
@callback handle_command(command, metadata) :: {:ok, result} | {:error, reason}
@callback validate_command(command) :: :ok | {:error, validation_errors}
```

## Development Guidelines

- **Contract-First**: Always create or identify the contract before implementing functionality
- **Use Scaffolding**: Use `mix arbor.gen.impl` to generate compliant implementations
- **Validate Early**: Run contract validation as part of your development workflow
- **Document Thoroughly**: All contracts must have comprehensive documentation

### Runtime Validation System

The project includes selective runtime validation using Norm schemas to catch contract violations that static analysis misses. This provides an additional layer of safety for critical operations.

#### When Runtime Validation is Applied

Runtime validation is **selectively applied** to high-risk operations:
- Gateway command processing (spawn_agent, etc.)
- Agent registration and lifecycle events  
- Session management operations
- Security-critical API boundaries

#### Configuration

Runtime validation can be enabled/disabled per environment:

```elixir
# config/dev.exs - Enable for development debugging
config :arbor_contracts, enable_validation: true

# config/test.exs - Usually disabled for test performance
config :arbor_contracts, enable_validation: false

# config/prod.exs - Disabled by default for production performance
config :arbor_contracts, enable_validation: false
```

#### Using Runtime Validation

For new critical operations, add validation using existing schemas:

```elixir
# In your module
alias Arbor.Contracts.Validation
alias Arbor.Contracts.Gateway.ValidationSchemas

def handle_spawn_agent_command(command) do
  # Validate command structure
  case Validation.validate(command, ValidationSchemas.spawn_agent_command()) do
    {:ok, validated_command} ->
      # Process validated command
      execute_spawn_agent(validated_command)
      
    {:error, reason} ->
      # Log validation failure and return error
      Logger.error("Command validation failed: #{reason}")
      {:error, {:validation_failed, reason}}
  end
end
```

#### Available Validation Schemas

Current schemas in `Arbor.Contracts.Gateway.ValidationSchemas`:
- `spawn_agent_command()` - Validates spawn_agent commands
- `command_context()` - Validates execution context
- `command_options()` - Validates command options
- `gateway_command_execution()` - Complete command execution

#### Performance Considerations

- Runtime validation has <5% performance overhead when enabled
- Validation is disabled by default in production
- Use `Validation.is_enabled?()` to check current status
- Failed validations emit telemetry events for monitoring

## Tool Preferences

- Whenever you need to write or edit code, prefer to use aider.
- Use `mix arbor.gen.impl` for all new contract implementations.

## Code Review Process

- After new code is written, use zen to review the code.
- Verify all contracts are properly implemented with `@behaviour` declarations.

## Development Principles

- Before writing or editing code, use zen to analyze it, get consensus on it, and plan it.
- Follow contract-first architecture - create the contract before the implementation.

## Tool Usage Guidelines

- **When to Use Aider**: 
  - When writing code that is expected to be longer than the prompt it will take to write it. 
  - If the prompt sent to aider will be longer than the code changes themselves, make the changes directly.