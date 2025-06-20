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