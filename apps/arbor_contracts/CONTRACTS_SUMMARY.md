# Arbor Contracts Summary

This document provides a comprehensive overview of all contracts defined in the `arbor_contracts` application for Phase 2 implementation.

## Contract Overview

### 1. Persistence Contracts

#### `Arbor.Contracts.Persistence.Store` (Behaviour)
- **Purpose**: Defines event store operations for event sourcing
- **Key Methods**:
  - `append_events/4` - Append events with version control
  - `read_events/4` - Read events from streams
  - `save_snapshot/3` - Save state snapshots
  - `transaction/3` - Atomic operations
- **Error Types**: `:version_conflict`, `:not_found`, `:transaction_failed`

#### `Arbor.Contracts.Events.Event` (Schema)
- **Purpose**: Immutable event structure for state changes
- **Key Fields**:
  - `type`, `aggregate_id`, `data` - Event identification
  - `causation_id`, `correlation_id`, `trace_id` - Distributed tracing
  - `stream_version`, `global_position` - Ordering
- **Version**: "1.0.0"

#### `Arbor.Contracts.Persistence.Snapshot` (Schema)
- **Purpose**: State snapshots for recovery optimization
- **Features**:
  - State compression support (gzip)
  - Integrity verification via hashing
  - Metadata for snapshot management
- **Version**: "1.0.0"

### 2. Security Contracts

#### `Arbor.Contracts.Security.Enforcer` (Behaviour)
- **Purpose**: Capability-based security enforcement
- **Key Methods**:
  - `authorize/5` - Make authorization decisions
  - `grant_capability/5` - Create new capabilities
  - `revoke_capability/5` - Invalidate capabilities
  - `delegate_capability/5` - Delegate with reduced permissions
- **Error Types**: `:capability_expired`, `:insufficient_permissions`, `:constraint_violation`

#### `Arbor.Contracts.Security.AuditEvent` (Schema)
- **Purpose**: Security audit trail for compliance
- **Event Types**:
  - Authorization events (success/denied)
  - Capability lifecycle (granted/revoked/delegated)
  - Policy violations and security alerts
- **Severity Levels**: `:critical`, `:high`, `:medium`, `:low`, `:info`

### 3. Session Management Contracts

#### `Arbor.Contracts.Session.Manager` (Behaviour)
- **Purpose**: Multi-agent session lifecycle management
- **Key Methods**:
  - `create_session/2` - Initialize new sessions
  - `spawn_agent/4` - Add agents to sessions
  - `update_session_context/4` - Share data across agents
  - `terminate_session/3` - Graceful cleanup
- **Error Types**: `:max_sessions_reached`, `:agent_spawn_failed`, `:invalid_state_transition`

#### `Arbor.Contracts.Core.Session` (Enhanced Schema)
- **Purpose**: Session state with lifecycle management
- **States**: `:initializing`, `:active`, `:suspended`, `:terminating`, `:terminated`, `:error`
- **Features**:
  - Agent registry with limits
  - Shared context management
  - Capability inheritance
  - Expiration handling

### 4. Distributed Coordination Contracts

#### `Arbor.Contracts.Cluster.Registry` (Behaviour)
- **Purpose**: Distributed process registration (Horde-based)
- **Key Methods**:
  - `register_name/4` - Unique name registration
  - `register_group/4` - Group membership
  - `register_with_ttl/5` - Time-limited registration
  - `monitor/2` - Process monitoring
- **Features**: Eventually consistent, partition tolerant

#### `Arbor.Contracts.Cluster.Supervisor` (Behaviour)
- **Purpose**: Distributed agent supervision
- **Key Methods**:
  - `start_agent/2` - Supervised agent startup
  - `migrate_agent/3` - Node-to-node migration
  - `handle_agent_handoff/4` - State preservation
- **Guarantees**: Automatic restart, state preservation, load balancing

### 5. Agent Coordination Contracts

#### `Arbor.Contracts.Agents.Coordinator` (Behaviour)
- **Purpose**: Inter-agent task delegation and coordination
- **Key Methods**:
  - `delegate_task/4` - Assign work to capable agents
  - `find_capable_agents/2` - Capability-based discovery
  - `broadcast/4` - One-to-many communication
  - `create_workflow/3` - Multi-step orchestration
- **Patterns**: Request-reply, pub-sub, workflow orchestration

#### `Arbor.Contracts.Agents.Messages` (Schemas)
- **Message Types**:
  - `TaskRequest/TaskResponse` - Task delegation
  - `AgentQuery/AgentInfo` - Agent discovery
  - `CapabilityRequest/CapabilityResponse` - Permission negotiation
  - `HealthCheck/HealthResponse` - Status monitoring
  - `CoordinationEvent` - Event notifications

### 6. Gateway Contracts

#### `Arbor.Contracts.Gateway.API` (Behaviour)
- **Purpose**: External client interface
- **Key Methods**:
  - `execute_command/3` - Process client commands
  - `subscribe_events/4` - Real-time event streaming
  - `check_rate_limit/4` - Rate limiting enforcement
- **Features**: Command validation, event subscriptions, health monitoring

### 7. Event Definitions

#### Agent Events (`Arbor.Contracts.Events.AgentEvents`)
- Lifecycle: `AgentStarted`, `AgentStopped`, `AgentCrashed`, `AgentRestarted`
- Communication: `MessageSent`, `MessageReceived`
- Tasks: `TaskAssigned`, `TaskCompleted`, `TaskFailed`
- Capabilities: `CapabilityGranted`, `CapabilityRevoked`

#### Session Events (`Arbor.Contracts.Events.SessionEvents`)
- Lifecycle: `SessionCreated`, `SessionTerminated`, `SessionExpired`
- Membership: `AgentJoinedSession`, `AgentLeftSession`
- State: `SessionStatusChanged`, `SessionContextUpdated`
- Operations: `CommandExecuted`, `SessionHealthChecked`

#### System Events (`Arbor.Contracts.Events.SystemEvents`)
- Cluster: `NodeJoined`, `NodeLeft`, `NetworkPartition`, `PartitionHealed`
- Resources: `ResourceAlert`, `PerformanceDegradation`
- Maintenance: `SystemUpgradeStarted`, `ConfigurationChanged`
- Health: `SystemHealthReport`, `SecurityIncident`

## Test Mocks (CLEARLY LABELED)

### `Arbor.Test.Mocks.InMemoryPersistence`
- **Purpose**: In-memory event store for testing
- **Features**: ETS-based storage, error injection, version conflict simulation
- **Warning**: TEST ONLY - Data lost on process termination

### `Arbor.Test.Mocks.PermissiveSecurity`
- **Purpose**: Permissive security for testing business logic
- **Features**: Allows all by default, configurable denials, tracks all attempts
- **Warning**: TEST ONLY - No actual security enforcement

### `Arbor.Test.Mocks.LocalRegistry`
- **Purpose**: Non-distributed registry for testing
- **Features**: Local process registration, TTL support, partition simulation
- **Warning**: TEST ONLY - Not distributed

## Contract Guidelines

1. **Versioning**: All contracts include `@version` attributes
2. **Error Handling**: Consistent error atoms across contracts
3. **Documentation**: Comprehensive docs with examples
4. **Type Safety**: Full typespecs for all functions
5. **Backwards Compatibility**: Changes require migration strategy

## Usage in Phase 2

These contracts enable strict Test-Driven Development:

1. **Write Tests First**: Use contracts to write failing tests
2. **Implement Against Contracts**: Build implementations that satisfy behaviors
3. **Mock for Isolation**: Use test mocks for unit testing
4. **Integration Testing**: Test real implementations together

## Next Steps

With these contracts defined and frozen, Phase 2 implementation can proceed with:

1. Unit tests for each contract implementation
2. Mock-based testing for isolation
3. Integration tests for component interaction
4. Performance tests for production readiness
5. Security audits for capability enforcement

All implementations must strictly adhere to these contracts to ensure system-wide compatibility and reliability.