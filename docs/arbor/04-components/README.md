# Section 04: Components

This section provides detailed specifications for Arbor's core components.

## Component Overview

Arbor is built as an umbrella application with clearly defined component boundaries:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   arbor_core    │────▶│ arbor_security  │────▶│ arbor_contracts │
└─────────────────┘     └─────────────────┘     └─────────────────┘
         │                       │
         └──────────┬────────────┘
                    ▼
          ┌─────────────────┐
          │arbor_persistence│
          └─────────────────┘
```

## Component Documentation

### arbor_core
The orchestration engine and runtime for agents.

- **[Specification](./arbor-core/specification.md)** - Complete component specification
- **[Gateway Patterns](./arbor-core/gateway-patterns.md)** - Client interaction patterns
- **[Agent Runtime](./arbor-core/agent-runtime.md)** *(Coming Soon)* - Agent lifecycle management

### arbor_security
Capability-based security implementation.

- **[Specification](./arbor-security/specification.md)** - Security component specification
- **[Capability Model](./arbor-security/capability-model.md)** *(Coming Soon)* - Detailed capability system

### arbor_persistence
State persistence and recovery layer.

- **[State Persistence](./arbor-persistence/state-persistence.md)** - Tiered persistence strategy

## Component Responsibilities

### arbor_contracts (Foundation)
- Zero-dependency contract definitions
- Shared types and behaviors
- Protocol specifications

### arbor_security (Security Layer)
- Capability validation and enforcement
- Security kernel implementation
- Audit logging

### arbor_persistence (Data Layer)
- State snapshots and recovery
- Event journaling
- Query interfaces

### arbor_core (Orchestration)
- Agent spawning and supervision
- Message routing
- Gateway services
- Session management

## Design Principles

1. **Clear Boundaries**: Each component has well-defined responsibilities
2. **Unidirectional Dependencies**: Dependencies flow in one direction only
3. **Contract-Driven**: All inter-component communication uses contracts
4. **Testable**: Each component can be tested in isolation

## Next Steps

- [Architecture](../05-architecture/README.md) - See how components interact
- [Infrastructure](../06-infrastructure/README.md) - Deploy components
- [Implementation](../07-implementation/README.md) - Develop with components