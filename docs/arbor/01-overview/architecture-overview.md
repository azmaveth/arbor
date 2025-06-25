# Arbor Architecture Overview
**Distributed Agent Orchestration System**

## Executive Overview

Arbor is a production-ready, distributed agent orchestration system built on Elixir/OTP principles. It evolved from the original MCP Chat session-based architecture into a robust platform for coordinating hundreds or thousands of specialized AI agents with near-100% uptime, capability-based security, and multi-client support.

**Core Value Propositions:**
- 🏗️ **Distributed by Default**: Fully implemented Horde-based cluster-wide agent management with two-tier supervision
- 🔐 **Security-First**: Production-ready SecurityKernel with fine-grained capability delegation and automatic revocation
- 📊 **Contracts-Driven**: Behavior-based contracts with Mox testing and optional Norm runtime validation
- ⚡ **High Performance**: Native BEAM communication with external protocol fallbacks
- 🔄 **Event-Driven**: Asynchronous operations with real-time progress updates via Phoenix.PubSub
- 🛡️ **Fault Tolerant**: Two-tier supervision strategy with immediate recovery and global reconciliation

## Core Architectural Principles

### 1. Contracts-First & Schema-Driven Design

The foundation of Arbor's architecture is the `arbor_contracts` application, which defines the system's "ubiquitous language" using a comprehensive validation approach:

```
Layer 0: Contracts (arbor_contracts) - Behavior definitions for compile-time interface enforcement
    ↓
Layer 1: Core Services - Implementation of behaviors with contract compliance
    ↓
Layer 2: Orchestration (arbor_core) - Agent runtime and coordination with Horde
    ↓
Layer 3: Gateways & Clients - Entry points with async command execution
```

**Contract Enforcement Strategy**:
- **Compile-time**: Behavior callbacks ensure interface compliance
- **Test-time**: Mox-based contract testing (99% code reduction achieved)
- **Runtime**: Optional Norm validation for critical boundaries (configurable per environment)

This multi-layered approach prevents circular dependencies, enables independent development, and ensures implementations stay synchronized with their contracts. The recent Mox migration has established patterns that dramatically improve test reliability and maintainability.

**BEAM Philosophy Alignment**: The contracts-first design enhances rather than contradicts the BEAM "let it crash" philosophy by handling expected operational errors (bad data) while allowing unexpected system errors (bugs) to crash cleanly. See [BEAM_PHILOSOPHY_AND_CONTRACTS.md](../02-philosophy/beam-philosophy.md) for detailed analysis.

### 2. Layered Umbrella Architecture

```
arbor_cli ─────┐
              ├──► arbor_core ──► arbor_security ──► arbor_contracts
arbor_web ─────┘                └─► arbor_persistence ──┘
```

**Dependency Flow Principles:**
- Dependencies flow in one direction only
- `arbor_contracts` has zero dependencies (pure contracts)
- Supporting services depend only on contracts
- Core depends on supporting services
- Clients depend on core

### 3. Distributed by Default (Fully Implemented)

The system uses **Horde** for distributed process management with a sophisticated two-tier supervision strategy:

**Tier 1: HordeSupervisor - Immediate Liveness**
- **Recovery Time**: Milliseconds
- **Scope**: Local process failures
- **Strategy**: `:one_for_one` supervision
- **Responsibility**: Immediate restart of failed agents based on `restart_strategy`

**Tier 2: AgentReconciler - Global State Reconciliation**
- **Recovery Time**: Seconds to minutes (configurable)
- **Scope**: Node failures, spec changes, scaling operations
- **Strategy**: Periodic reconciliation of desired vs actual state
- **Responsibility**: Redistributing agents from failed nodes, rolling updates, consistency audits

**Production Features**:
- Cluster-wide agent registry with location transparency
- Automatic failover on node failure with state recovery
- Process handoff during rolling upgrades
- Horizontal scalability across multiple nodes (tested up to 100 nodes)
- Race condition handling for stale registrations

### 4. Production-Ready Capability-Based Security

The `SecurityKernel` GenServer provides centralized, auditable security enforcement:

**Core Features**:
- **Zero-Trust Model**: Agents start with zero permissions
- **Delegatable Capabilities**: Fine-grained permissions with constraint propagation
- **Automatic Revocation**: Process monitoring ensures capabilities die with their processes
- **PostgreSQL Persistence**: All capabilities and audit logs persisted to database
- **Comprehensive Telemetry**: Security events emitted for monitoring and alerting

**Implementation Details**:
- `Process.monitor/1` tracks capability holders
- Handles `:DOWN` messages to revoke orphaned capabilities
- Integrates with `CapabilityStore` and `AuditLogger` backends
- Schema changes in security tables require careful migration planning

### 5. Asynchronous & Event-Driven

All long-running operations follow the async command/event pattern:
- Immediate acknowledgment with execution IDs
- Real-time progress via Phoenix PubSub
- Multi-client support with independent subscriptions

## The Arbor Agent Model

### Agent Taxonomy

Arbor uses a **two-tiered agent taxonomy** that evolved from the original MCP Chat session-based model:

#### Coordinator Agents
- **Purpose**: Long-lived, stateful GenServers that manage high-level tasks or user sessions
- **Lifecycle**: Persistent, survive individual task failures
- **Responsibilities**: Task decomposition, worker spawning, result aggregation
- **Evolution**: Evolved from the original `MCPChat.Session` processes
- **Examples**: `Arbor.Core.Sessions.Session`, workflow coordinators

#### Worker Agents  
- **Purpose**: Ephemeral, task-specific GenServers (`restart: :temporary`)
- **Lifecycle**: Spawn → Execute → Terminate
- **Responsibilities**: Single, well-defined operations
- **Security**: Receive delegated, constrained capabilities
- **Examples**: `ToolExecutorAgent`, `ExportAgent`, file processors

### The Arbor.Agent Contract

All agents implement the core `Arbor.Agent` behaviour:

```elixir
@callback init(args :: any()) :: {:ok, state()} | {:stop, reason()}
@callback handle_message(message :: Envelope.t(), state()) :: 
  {:noreply, state()} | {:reply, reply :: any(), state()} | {:stop, reason(), state()}
@callback handle_capability(capability :: Capability.t(), state()) ::
  {:ok, state()} | {:error, reason()}
@callback terminate(reason :: reason(), state()) :: :ok
@callback export_state(state()) :: map()
@callback import_state(persisted :: map()) :: {:ok, state()} | {:error, reason()}
```

## System Components & Integration

### Runtime Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Client Layer                             │
│  ┌─────────────────┐              ┌─────────────────────────┐   │
│  │   CLI Client    │              │    Web UI (Phoenix)     │   │
│  │  (arbor_cli)    │              │    (arbor_web)         │   │
│  └─────────────────┘              └─────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
           │                                    │
           │ (Gateway API)                      │ (Phoenix Channels)
           └───────────────────┬────────────────┘
                               │
┌─────────────────────────────────────────────────────────────────┐
│                     arbor_core                                  │
│                                                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐ │
│  │     Gateway     │    │  Agent Runtime  │    │  Messaging  │ │
│  │  (Entry Point)  │    │  (Coordination) │    │   Router    │ │
│  └─────────────────┘    └─────────────────┘    └─────────────┘ │
│           │                       │                     │       │
└───────────┼───────────────────────┼─────────────────────┼───────┘
            │                       │                     │
    ┌───────┴──────┐        ┌──────┴──────┐      ┌──────┴──────┐
    │              │        │             │      │             │
┌───▼────┐  ┌─────▼────┐  ┌▼─────────────▼┐    ┌▼─────────────▼┐
│Security│  │Persistence│  │  Distributed   │    │    Events &    │
│Kernel  │  │  Manager  │  │     Horde      │    │    PubSub     │
│        │  │           │  │   Registry     │    │               │
└────────┘  └──────────┘  └────────────────┘    └───────────────┘
```

### Core Components

#### `arbor_contracts`: The Shared Language
- **Purpose**: System-wide contracts, behaviors, and validation
- **Key Assets**: Behavior definitions, Norm schemas, validation infrastructure
- **Dependencies**: None (zero dependency rule)
- **Contract Strategy**: 
  - Behaviors for compile-time interface enforcement
  - Mox for contract-based testing
  - Norm for optional runtime validation
- **Critical Files**: Gateway.API, Cluster.Supervisor, Session.Manager behaviors

#### `arbor_security`: The Capability Engine  
- **Purpose**: Production-ready, fine-grained access control
- **Key Component**: `SecurityKernel` GenServer with process monitoring
- **Security Model**: 
  - Zero-trust capability-based permissions
  - Automatic revocation on process death
  - PostgreSQL-backed persistence
  - Comprehensive audit logging
- **Integration**: All operations validated through SecurityKernel

#### `arbor_persistence`: State Persistence Layer
Implements a **tiered persistence strategy** optimized for performance vs. reliability:

- **Critical State** (journaled): User messages, agent responses, capability grants
- **Recoverable State** (not journaled): UI state, temporary data, progress indicators
- **Architecture**: ETS hot storage + selective event journaling + periodic snapshots
- **Recovery Time**: <1 second for process crashes, <30 seconds for node failures

#### `arbor_core`: Orchestration & Runtime Engine
- **Agent Management**: Spawning, supervision, lifecycle management
- **Message Routing**: Inter-agent communication with transport abstraction
- **Session Management**: Coordinator agent lifecycle
- **Gateway Services**: Single entry point for all client interactions

#### Clients (`arbor_web`/`arbor_cli`): System Consumers
- **Web Dashboard**: Phoenix LiveView with real-time updates
- **CLI Interface**: Interactive command-line client
- **API Gateway**: RESTful and WebSocket APIs for external integrations

## Core Interaction Patterns

### 1. The Gateway Pattern

All client interactions flow through `Arbor.Core.Gateway` which provides:
- **Authentication & Authorization**: Session management and capability validation
- **Capability Discovery**: Dynamic enumeration of available operations
- **Async Operation Management**: Execution ID generation and tracking
- **Event Routing**: PubSub topic management for real-time updates

### 2. Dynamic Capability Discovery

Agents advertise their capabilities dynamically, enabling extensible systems:

```elixir
# Agents implement capability listing
@callback list_capabilities() :: [Arbor.Agent.Capability.t()]

# Clients discover available operations
{:ok, capabilities} = Arbor.Core.Gateway.discover_capabilities(session_id)

# Capabilities are filtered based on client permissions
authorized_capabilities = filter_by_permissions(capabilities, client_capabilities)
```

### 3. Secure Asynchronous Command Flow

The core interaction pattern for all operations:

```
1. Client Request
   ├─► Gateway.execute_command(session_id, command, params)
   
2. Security Validation  
   ├─► SecurityKernel validates client capabilities
   ├─► Gateway spawns appropriate agent type
   ├─► Gateway delegates constrained capability to agent
   
3. Immediate Response
   ├─► {:async, execution_id}
   
4. Client Subscription
   ├─► PubSub.subscribe("execution:#{execution_id}")
   
5. Agent Execution
   ├─► Agent broadcasts progress events
   ├─► Agent completes work and broadcasts result
   ├─► Agent terminates (capability auto-revoked)
   
6. Event Consumption
   ├─► Client receives real-time progress updates
   └─► Client handles completion/failure events
```

This pattern enables:
- **Non-blocking operations**: Clients remain responsive
- **Multi-client support**: Multiple UIs can subscribe to same execution
- **Real-time feedback**: Progress updates for long-running tasks
- **Fault isolation**: Agent failures don't affect client sessions

## Advanced Patterns

### Contract-Based Testing Infrastructure

The project has evolved a sophisticated testing strategy that ensures implementation compliance:

**Mox Migration Achievement**:
- **99% code reduction** for migrated test mocks
- **Contract enforcement** at test time
- **Improved reliability** through elimination of timing dependencies
- **Helper functions** in `MoxSetup` reduce boilerplate

**Testing Patterns**:
```elixir
# Instead of hand-written mocks with state
expect(MockModule, :function_name, fn arg ->
  assert arg == expected_value
  {:ok, result}
end)

# Message passing for async testing
test_pid = self()
stub(SupervisorMock, :start_agent, fn spec ->
  send(test_pid, {:supervisor_called, spec})
  {:ok, self()}
end)
assert_receive {:supervisor_called, _spec}, 1000
```

### Native Agent Communication

For performance-critical operations, Arbor implements a **dual-path communication architecture**:

- **BEAM Native**: Direct message passing for same-cluster agents (~15μs latency)
- **External Protocols**: Serialized protocols (MCP, HTTP) for non-BEAM clients (~1-5ms+)

This enables 200-300x performance improvements for agent-to-agent coordination while maintaining compatibility with external systems.

### Event-Sourced State Management

All state changes are captured as events for:
- **Complete audit trail**: Every action is traceable
- **Time-travel debugging**: Replay system state at any point
- **State reconstruction**: Recover from any failure point
- **Eventually consistent views**: Multiple read models from same events

## Evolution from MCP Chat

Arbor represents a significant architectural evolution while preserving proven patterns:

| MCP Chat Concept | Arbor Evolution | Key Improvements |
|------------------|-----------------|------------------|
| `MCPChat.Session` | Coordinator Agent | Distributed, fault-tolerant |
| Direct tool execution | Worker Agents | Isolated, capability-constrained |
| Session state | Event-sourced persistence | Recoverable, auditable |
| UI-coupled logic | Gateway abstraction | Multi-client, API-driven |
| Simple permissions | Capability delegation | Fine-grained, delegatable |
| Single-node | Horde distribution | Cluster-wide, location-transparent |

## Implementation Status

### Phase 1: Foundation ✅
- [x] Create umbrella structure
- [x] Implement `arbor_contracts` with behavior-based contracts
- [x] Production `arbor_security` with SecurityKernel
- [x] Event-sourced `arbor_persistence` with PostgreSQL backend
- [x] Full `arbor_core` with Gateway pattern
- [x] Interactive `arbor_cli` client

### Phase 2: Production Hardening ✅
- [x] Distributed operation with Horde (two-tier supervision)
- [x] PostgreSQL persistence backend (capabilities, audit logs, events)
- [x] Contract-based testing with Mox (99% code reduction)
- [x] Comprehensive telemetry and monitoring
- [x] Performance optimization with native BEAM communication

### Phase 3: Testing & Quality ✅
- [x] Mox migration for contract-based testing
- [x] Two-tier supervision strategy
- [x] Async command execution with event streaming
- [x] Process-linked capability revocation

### Phase 4: Advanced Features 🚧
- [ ] Chaos testing for network partitions
- [ ] Property-based testing for distributed edge cases
- [ ] Multi-region deployment
- [ ] Advanced scheduling algorithms
- [ ] External system integrations beyond MCP

## Glossary

- **Agent**: A GenServer that implements the `Arbor.Agent` behaviour
  - **Coordinator Agent**: Long-lived, manages high-level tasks
  - **Worker Agent**: Ephemeral, performs specific operations
- **Capability**: A permission grant for accessing specific resources
- **Gateway**: Single entry point for all client interactions (`Arbor.Core.Gateway`)
- **Session**: A user's interaction context, managed by a Coordinator Agent
- **Registry**: Distributed process registry using Horde
- **Execution ID**: Unique identifier for async operations
- **Contract**: Formal interface definition in `arbor_contracts`
- **SecurityKernel**: Central authority for capability validation

## Operational Considerations

### Scaling Limits

- **Horde**: Tested up to 100 nodes; beyond this, consider libcluster + sharding
- **PostgreSQL**: Single-writer bottleneck for SecurityKernel; plan read replicas for audit queries
- **Phoenix.PubSub**: Scales well but consider Redis adapter for >1000 concurrent clients

### Critical Operational Tasks

1. **Chaos Testing**: Required for production - test network partitions, split-brain scenarios
2. **Capability Migration**: Schema changes require careful planning due to security implications
3. **Contract Versioning**: Establish governance before interfaces proliferate
4. **Monitoring**: Comprehensive telemetry already emitted; dashboards needed

### Known Edge Cases

- **Supervision Restarts**: May cause capability revocation if not handled idempotently
- **Race Conditions**: Handled in HordeSupervisor but require periodic reconciliation
- **Network Partitions**: Two-tier supervision helps but manual intervention may be needed

## Related Documents

- **[BEAM_PHILOSOPHY_AND_CONTRACTS.md](../02-philosophy/beam-philosophy.md)**: BEAM philosophy and contracts-first design alignment
- **[ARBOR_CONTRACTS.md](../03-contracts/core-contracts.md)**: Complete contract specifications
- **[UMBRELLA_ARCHITECTURE.md](./umbrella-structure.md)**: Umbrella application structure
- **[MIGRATION_COOKBOOK.md](../../../MIGRATION_COOKBOOK.md)**: Mox migration patterns and examples
- **[architecture/NATIVE_AGENT_COMMUNICATION.md](../05-architecture/communication-patterns.md)**: High-performance communication patterns
- **[architecture/GATEWAY_AND_DISCOVERY_PATTERNS.md](../04-components/arbor-core/gateway-patterns.md)**: Client interaction patterns
- **[architecture/STATE_PERSISTENCE_DESIGN.md](../04-components/arbor-persistence/state-persistence.md)**: Tiered persistence strategy

---

*This overview reflects the current production implementation as of Phase 3 completion. The architecture has evolved significantly from initial designs to deliver a robust, scalable distributed system.*
