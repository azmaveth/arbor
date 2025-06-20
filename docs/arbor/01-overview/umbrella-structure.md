# Arbor Umbrella Architecture

## Overview

Arbor is being restructured as an Elixir umbrella application to create a production-ready, distributed AI agent orchestration system. This document provides the high-level architecture and serves as the entry point for understanding the system.

## Goals

1. **Near 100% Uptime**: Agents maintain state between crashes, upgrades, and node failures
2. **Headless Operation**: Core agent runtime operates independently of any UI
3. **Multi-Client Support**: CLI, Web UI, and future clients can connect/disconnect at will
4. **Massive Scale**: Support for hundreds/thousands of coordinated agents
5. **Production Ready**: Comprehensive security, monitoring, and operational tooling

## Umbrella Structure

```
arbor_umbrella/
├── apps/
│   ├── arbor_contracts/    # Shared contracts, types, and behaviours
│   ├── arbor_security/     # Capability-based security implementation
│   ├── arbor_persistence/  # State persistence and recovery
│   ├── arbor_core/         # Agent runtime and coordination
│   ├── arbor_web/          # Phoenix web UI and API
│   └── arbor_cli/          # Command-line client
├── config/
├── deps/
└── mix.exs
```

## Application Dependency Flow

```
arbor_cli ─────┐
              ├──► arbor_core ──► arbor_security ──► arbor_contracts
arbor_web ─────┘                └─► arbor_persistence ──┘
```

Key principles:
- Dependencies flow in one direction only
- `arbor_contracts` has no dependencies
- Supporting services (security, persistence) depend only on contracts
- Core depends on supporting services
- Clients depend on core

## Key Design Decisions

### 1. Contracts-First Design

`arbor_contracts` defines all contracts before implementation. This ensures:
- Clear API boundaries between applications
- No circular dependencies
- Easy testing with mocks/stubs
- Multiple implementations possible

### 2. Distributed by Default

Using Horde for distributed process management:
- Cluster-wide agent registry
- Automatic failover on node failure
- Process handoff during rolling upgrades
- Location transparency for agents

### 3. Event-Sourced State

All state changes are events:
- Complete audit trail
- Time-travel debugging
- State reconstruction after crashes
- Eventually consistent views

### 4. Capability-Based Security

Fine-grained permissions:
- Agents start with zero permissions
- Explicit capability grants required
- Delegation with constraints
- Automatic revocation on termination

## Implementation Phases

### Phase 1: Foundation (Current)
- [ ] Create umbrella structure
- [ ] Implement `arbor_contracts` contracts
- [ ] Basic `arbor_security` with OTP isolation
- [ ] Simple `arbor_persistence` with DETS
- [ ] Minimal viable `arbor_core`
- [ ] Basic `arbor_cli` client

### Phase 2: Production Hardening
- [ ] Distributed operation with Horde
- [ ] PostgreSQL persistence backend
- [ ] Web dashboard with Phoenix LiveView
- [ ] Comprehensive telemetry and monitoring
- [ ] Performance optimization

### Phase 3: Advanced Features
- [ ] Multi-region deployment
- [ ] Advanced scheduling algorithms
- [ ] Machine learning integration
- [ ] External system integrations

## Next Steps

1. **Start Here**: Review [architecture-overview.md](./architecture-overview.md) for the complete architectural vision
2. Review [core-contracts.md](../03-contracts/core-contracts.md) for contract definitions
3. Review individual app specifications in their respective README files
4. Follow [IMPLEMENTATION_GUIDE.md](./IMPLEMENTATION_GUIDE.md) for step-by-step setup

## Related Documents

- [state-persistence.md](../04-components/arbor-persistence/state-persistence.md) - Persistence layer design
- [agent-architecture.md](../05-architecture/agent-architecture.md) - Agent coordination patterns
- [gateway-patterns.md](../04-components/arbor-core/gateway-patterns.md) - Dynamic capability discovery and gateway patterns
- [communication-patterns.md](../05-architecture/communication-patterns.md) - High-performance native communication for same-node agents