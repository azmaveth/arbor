# Arbor Umbrella Architecture

## Overview

Arbor is a production-ready, distributed AI agent orchestration system built as an Elixir umbrella application. This document provides the high-level architecture and serves as the entry point for understanding the system.

## Current Production State

The Arbor system is now in production with the following capabilities fully implemented:
- ✅ **Distributed Architecture**: Full Horde-based cluster management with automatic failover
- ✅ **Contract System**: Dual-contract system with TypedStruct for data and behaviors for interfaces
- ✅ **Security**: Capability-based security kernel with fine-grained permissions
- ✅ **Two-Tier Supervision**: HordeSupervisor for immediate recovery + AgentReconciler for global consistency
- ✅ **Event Streaming**: Gateway with async command execution and real-time updates
- ✅ **Production Monitoring**: Comprehensive telemetry and observability

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

### Phase 1: Foundation ✅ COMPLETE
- ✅ Create umbrella structure
- ✅ Implement `arbor_contracts` contracts with dual-contract system
- ✅ Production `arbor_security` with capability-based security kernel
- ✅ Event-sourced `arbor_persistence` with selective journaling
- ✅ Full-featured `arbor_core` with Gateway pattern
- ✅ Working `arbor_cli` client with event streaming

### Phase 2: Production Hardening ✅ COMPLETE
- ✅ Distributed operation with Horde (cluster-wide coordination)
- ✅ PostgreSQL persistence backend (event store + hot cache)
- ⏳ Web dashboard with Phoenix LiveView (planned)
- ✅ Comprehensive telemetry and monitoring (OpenTelemetry integration)
- ✅ Performance optimization (FastAuthorizer pattern)

### Phase 3: Advanced Features ⏳ IN PROGRESS
- ✅ Multi-node deployment with automatic agent redistribution
- ⏳ Advanced scheduling algorithms (basic version complete)
- ⏳ Machine learning integration (architecture defined)
- ✅ External system integrations (MCP protocol support)

## Next Steps

1. **Start Here**: Review [architecture-overview.md](./architecture-overview.md) for the complete architectural vision
2. Review [core-contracts.md](../03-contracts/core-contracts.md) for contract definitions
3. Review individual app specifications in their respective README files
4. Follow [IMPLEMENTATION_GUIDE.md](./IMPLEMENTATION_GUIDE.md) for step-by-step setup

## Related Documents

- [state-persistence.md](../04-components/arbor-persistence/state-persistence.md) - Persistence layer design
- [gateway-patterns.md](../04-components/arbor-core/gateway-patterns.md) - Dynamic capability discovery and gateway patterns
- [communication-patterns.md](../05-architecture/communication-patterns.md) - High-performance native communication for same-node agents
- [Architecture Overview](./architecture-overview.md) - Comprehensive current architecture
- [Core Contracts](../03-contracts/core-contracts.md) - Contract specifications