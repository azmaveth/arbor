# Arbor Phase 2: Production Hardening & Core Functionality Implementation Plan

## Overview

This plan details the implementation of Arbor's core production-ready features, moving from the foundational MVP to a resilient, distributed, and functional system. Phase 2 focuses on building out the production-grade implementations of persistence, security, and distributed operation that were established as placeholders in Phase 1.

## Key Goals

1. **Production Persistence**: Replace DETS-based storage with PostgreSQL and event sourcing
2. **Robust Security**: Implement full capability-based security with automatic revocation
3. **Distributed Operation**: Enable true multi-node clustering with Horde
4. **Real-time UI**: Build Phoenix LiveView dashboard for monitoring and control
5. **Comprehensive Observability**: Implement three-pillar observability stack

## Phase 2 Implementation Steps

### Step 0: Define and Freeze Comprehensive Contracts

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/03-contracts/core-contracts.md` - Study the contracts-first design approach and existing contract patterns
- `docs/arbor/03-contracts/schema-driven-design.md` - Understand schema and behavior definition standards

BEFORE STARTING: Verify prerequisites are met - confirm arbor_contracts application exists with basic structure from Phase 1, and review existing contracts (Agent, Message, Capability).

Define comprehensive contracts for all Phase 2 features to enable test-driven development. This step establishes the 'source of truth' for all subsequent implementation:

1. **Event Sourcing & Persistence Contracts:**
   - `Arbor.Contracts.Persistence.Store` behaviour with granular error types
   - `Arbor.Contracts.Events.Event` schema with validation
   - `Arbor.Contracts.Persistence.Snapshot` schema for state optimization

2. **Security Enforcement Contracts:**
   - `Arbor.Contracts.Security.Enforcer` behaviour for capability validation
   - `Arbor.Contracts.Security.AuditEvent` schema for security logging
   - Granular error types for authorization failures

3. **Session Management Contracts:**
   - `Arbor.Contracts.Session.Manager` behaviour with complete lifecycle
   - Enhanced `Arbor.Contracts.Core.Session` schema with state transitions
   - Session context and capability management contracts

4. **Distributed Coordination Contracts:**
   - `Arbor.Contracts.Cluster.Registry` behaviour leveraging Horde patterns
   - `Arbor.Contracts.Cluster.Supervisor` behaviour for distributed agents
   - Node coordination and migration contracts

5. **Agent Coordination Contracts:**
   - `Arbor.Contracts.Agents.Coordinator` behaviour for inter-agent communication
   - Message schemas for `TaskRequest`, `TaskResponse`, and coordination events
   - Agent delegation and capability request contracts

6. **Gateway Operation Contracts:**
   - `Arbor.Contracts.Gateway.API` behaviour for command execution
   - Execution tracking and status reporting contracts
   - Event subscription and notification contracts

7. **Test Mock Implementations:** (CLEARLY LABELED AS MOCKS)
   - `Arbor.Test.Mocks.InMemoryPersistence` - Mock persistence adapter
   - `Arbor.Test.Mocks.PermissiveSecurity` - Mock security enforcer
   - `Arbor.Test.Mocks.LocalRegistry` - Mock distributed registry

For each contract:
- Define precise `@type` specifications with granular error types
- Include `@version` attributes for compatibility tracking
- Add behavioural documentation with Given/When/Then examples
- Create empty stub modules that implement behaviors (compilation targets)
- Add CI validation to prevent accidental contract changes

AFTER COMPLETION: Verify postrequisites are achieved - confirm all contracts compile without warnings, stub implementations satisfy behaviours, comprehensive error types are defined, mock implementations are clearly labeled, and CI validates contract stability."

**Reference Documentation:**

- [Core Contracts](../03-contracts/core-contracts.md) - Contracts-first design approach
- [Schema Driven Design](../03-contracts/schema-driven-design.md) - Schema definition standards

**Prerequisites:**

- arbor_contracts application exists with basic structure
- Existing contracts (Agent, Message, Capability) reviewed

**Contract Implementation Structure:**

```elixir
# Example: lib/arbor/contracts/session/manager.ex
defmodule Arbor.Contracts.Session.Manager do
  @moduledoc """
  Contract for session management operations.
  
  ## Behavioral Examples
  
  ### Creating a Session
  Given: Valid session parameters with user ID and capabilities
  When: create_session/1 is called
  Then: Returns {:ok, Session.t()} with assigned ID and active status
  
  ### Invalid Parameters
  Given: Session parameters missing required fields
  When: create_session/1 is called  
  Then: Returns {:error, {:invalid_params, :missing_created_by}}
  """
  
  @version "1.0"
  
  @type session_id :: String.t()
  @type session_params :: %{
    created_by: String.t(),
    context: map(),
    capabilities: [String.t()],
    expires_at: DateTime.t() | nil
  }
  
  @callback create_session(session_params()) :: 
    {:ok, Session.t()} | 
    {:error, {:invalid_params, :missing_created_by | :invalid_expires_at} | 
             :unauthorized | term()}
end

# Stub implementation for compilation
defmodule Arbor.Core.SessionManager do
  @behaviour Arbor.Contracts.Session.Manager
  
  def create_session(_params), do: {:error, :not_implemented}
end

# Mock for testing - CLEARLY LABELED
defmodule Arbor.Test.Mocks.SessionManager do
  @moduledoc """
  MOCK IMPLEMENTATION FOR TESTING ONLY
  This is a test double that provides predictable responses.
  Replace with real implementation before production.
  """
  
  @behaviour Arbor.Contracts.Session.Manager
  
  def create_session(params) do
    # Configurable mock behavior for testing
  end
end
```

**Postrequisites:**

- All contract modules compile without warnings
- Stub implementations satisfy all behaviour requirements
- Granular error types defined for precise testing
- Mock implementations clearly labeled as test-only
- CI pipeline validates contract stability

---

### Step 1: Implement Production Persistence Layer (TDD Approach)

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/04-components/arbor-persistence/state-persistence.md` - Study the multi-tiered persistence architecture
- `docs/arbor/06-infrastructure/tooling-analysis.md` - Review PostgreSQL and Ecto recommendations
- Step 0 contracts: `Arbor.Contracts.Persistence.Store` and `Arbor.Contracts.Events.Event` behaviors

BEFORE STARTING: Verify prerequisites are met - confirm Step 0 contracts are implemented and frozen, `arbor_persistence` application exists, and PostgreSQL is available via Docker.

Use layered test-driven development to implement the production persistence layer:

## PHASE A: UNIT TDD (Red-Green-Refactor)

Write failing unit tests for each contract clause, then implement minimal code to pass:

1. **Test Event Schema Validation:**
   ```elixir
   defmodule Arbor.Persistence.EventTest do
     test "creates valid event with required fields" do
       params = %{stream_id: "test-123", event_type: "StateChanged", data: %{}}
       assert {:ok, %Event{}} = Event.new(params)
     end
     
     test "rejects event with missing stream_id" do
       params = %{event_type: "StateChanged", data: %{}}
       assert {:error, {:invalid_params, :missing_stream_id}} = Event.new(params)
     end
   end
   ```

2. **Test Store Behaviour Implementation:**
   Write unit tests for each `@callback` in `Arbor.Contracts.Persistence.Store`:
   - `append_events/3` success and version mismatch scenarios
   - `read_events/2` with valid and invalid stream IDs
   - `save_state/2` and `get_state/1` roundtrip testing
   - All granular error types defined in contracts

3. **Test ETS Cache Logic:**
   Unit test cache hit/miss scenarios without database dependency

4. **Test Event Journal Batching:**
   Unit test batching logic with mock event writer

Use **MOCK IMPLEMENTATIONS** from Step 0 for any external dependencies during unit testing.

## PHASE B: INTEGRATION TDD

5. **Write Failing Integration Test:**
   ```elixir
   defmodule Arbor.Persistence.IntegrationTest do
     use ExUnit.Case
     @moduletag :integration
     
     test "complete persistence workflow with database" do
       # This test will initially fail
       {:ok, _} = Arbor.Persistence.Store.append_events("stream-1", [event1, event2], 0)
       assert {:ok, events} = Arbor.Persistence.Store.read_events("stream-1", 0)
       assert length(events) == 2
       
       # Test state persistence and recovery
       :ok = Arbor.Persistence.Store.save_state("entity-1", %{count: 42})
       assert {:ok, %{count: 42}} = Arbor.Persistence.Store.get_state("entity-1")
     end
   end
   ```

6. **Implement Production Components:**
   - Add `ecto_sql`, `postgrex`, `jason` dependencies
   - Create `Arbor.Persistence.Repo` with proper configuration
   - Define Ecto schemas matching contract specifications
   - Implement `Arbor.Persistence.Store` GenServer
   - Create database migrations
   - Add telemetry and error handling

7. **Integration Test Passes:**
   Use Testcontainers or Docker for ephemeral PostgreSQL during testing

## TESTING REQUIREMENTS

- **Unit Tests:** Mock all external dependencies using Step 0 mocks
- **Integration Tests:** Use real PostgreSQL via Docker/Testcontainers  
- **Property Tests:** Generate random events and verify roundtrip persistence
- **Performance Tests:** Verify ETS cache improves read latency

## MOCK USAGE (CLEARLY LABELED)

Use these **MOCK IMPLEMENTATIONS** for unit testing:
- `Arbor.Test.Mocks.InMemoryPersistence` for database-free unit tests
- Mark all mock usage with comments: `# MOCK: Replace with real implementation`

AFTER COMPLETION: Verify postrequisites are achieved - all unit tests pass with mocks, integration test passes with real PostgreSQL, event sourcing workflow verified, ETS cache demonstrates performance improvement, and all mocks are clearly identified for future replacement."

**Reference Documentation:**

- [State Persistence](../04-components/arbor-persistence/state-persistence.md) - Multi-tiered persistence architecture
- [Tooling Analysis](../06-infrastructure/tooling-analysis.md) - PostgreSQL and Ecto recommendations
- [Core Contracts](../03-contracts/core-contracts.md) - Store behaviour definition

**Prerequisites:**

- `arbor_persistence` application exists with basic structure
- PostgreSQL available for development
- Phase 1 DETS-based storage in place

**Dependencies to Add:**

```elixir
# In apps/arbor_persistence/mix.exs
defp deps do
  [
    {:arbor_contracts, in_umbrella: true},
    {:ecto_sql, "~> 3.11"},
    {:postgrex, "~> 0.17"},
    {:jason, "~> 1.4"}
  ]
end
```

**Database Configuration:**

```elixir
# In config/dev.exs
config :arbor_persistence, Arbor.Persistence.Repo,
  username: "arbor_dev",
  password: "arbor_dev",
  hostname: "localhost",
  database: "arbor_dev",
  pool_size: 10
```

**Postrequisites:**

- PostgreSQL-based persistence fully operational
- Event sourcing with journal and snapshots implemented
- State recovery after restart verified
- ETS caching layer improves performance
- Database migrations and schema properly configured

---

### Step 2: Implement Production Security System (TDD Approach)

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/04-components/arbor-security/specification.md` - Study the SecurityKernel design and capability lifecycle
- Step 0 contracts: `Arbor.Contracts.Security.Enforcer` and `Arbor.Contracts.Security.AuditEvent` behaviors
- `docs/arbor/02-philosophy/beam-philosophy.md` - Understand defensive programming principles

BEFORE STARTING: Verify prerequisites are met - confirm Step 0 security contracts are frozen, production persistence layer is operational, and `arbor_security` application exists.

Use layered test-driven development to implement the capability-based security system:

## PHASE A: UNIT TDD (Red-Green-Refactor)

Write failing unit tests for each security contract clause:

1. **Test Capability Validation Logic:**
   ```elixir
   defmodule Arbor.Security.EnforcerTest do
     test "validates capability with correct permissions" do
       capability = %Capability{
         agent_id: "agent-123",
         resource_uri: "file://data/reports.csv",
         operation: :read,
         expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
       }
       # MOCK: Use test capability store
       assert :allowed = SecurityEnforcer.check_permission("agent-123", "file://data/reports.csv", :read)
     end
     
     test "denies access for expired capability" do
       expired_capability = %Capability{expires_at: DateTime.add(DateTime.utc_now(), -1, :second)}
       assert {:denied, :expired} = SecurityEnforcer.check_permission("agent-123", "resource", :read)
     end
   end
   ```

2. **Test Capability Delegation:**
   - Unit test delegation with reduced permissions
   - Test delegation depth limits
   - Verify delegation chain validation

3. **Test Automatic Revocation:**
   - Unit test process monitoring and capability cleanup
   - Test cascading revocation for delegated capabilities

4. **Test Audit Event Generation:**
   Unit test audit event creation for each security operation using contracts

Use **MOCK IMPLEMENTATIONS** from Step 0 for persistence and external dependencies.

## PHASE B: INTEGRATION TDD

5. **Write Failing Integration Test:**
   ```elixir
   defmodule Arbor.Security.IntegrationTest do
     use ExUnit.Case
     @moduletag :integration
     
     test "complete capability lifecycle with persistence" do
       # Grant capability
       {:ok, capability} = SecurityKernel.grant_capability(%{
         agent_id: "agent-123",
         resource_uri: "file://test.txt",
         operation: :read
       })
       
       # Validate capability works
       assert :allowed = SecurityKernel.check_permission("agent-123", "file://test.txt", :read)
       
       # Revoke capability
       :ok = SecurityKernel.revoke_capability(capability.id, :manual)
       
       # Verify access denied
       assert {:denied, :revoked} = SecurityKernel.check_permission("agent-123", "file://test.txt", :read)
       
       # Verify audit trail exists
       assert [%AuditEvent{event_type: :grant}, %AuditEvent{event_type: :revoke}] = 
         SecurityKernel.get_audit_trail("agent-123")
     end
   end
   ```

6. **Implement Production Components:**
   - `Arbor.Security.Kernel` GenServer implementing zero-trust validation
   - `Arbor.Security.CapabilityStore` with PostgreSQL + ETS caching
   - `Arbor.Security.AuditLogger` with telemetry integration
   - Process monitoring for automatic capability revocation
   - Resource adapters for different capability types

7. **Integration Test Passes:**
   Use real persistence layer and verify audit trail integrity

## TESTING REQUIREMENTS

- **Unit Tests:** Test each security policy in isolation with mocks
- **Security Tests:** Test all attack vectors (expired, wrong permissions, etc.)
- **Property Tests:** Generate random capability scenarios and verify enforcement
- **Process Tests:** Verify automatic cleanup when processes terminate

## MOCK USAGE (CLEARLY LABELED)

Use these **MOCK IMPLEMENTATIONS** for unit testing:
- `Arbor.Test.Mocks.PermissiveSecurity` for permissive testing scenarios
- `Arbor.Test.Mocks.RestrictiveSecurity` for denial testing scenarios  
- Mark all mock usage: `# MOCK: Replace with SecurityKernel for production`

## SECURITY TESTING PATTERNS

Test each capability operation with:
- **Valid capability:** Should succeed
- **No capability:** Should deny with `:unauthorized`
- **Wrong resource:** Should deny with `:forbidden`
- **Expired capability:** Should deny with `:expired`
- **Revoked capability:** Should deny with `:revoked`

AFTER COMPLETION: Verify postrequisites are achieved - zero-trust validation enforced, all security test patterns pass, audit trail captures all operations, automatic revocation working, and all security mocks clearly labeled."

**Reference Documentation:**

- [Security Specification](../04-components/arbor-security/specification.md) - Complete SecurityKernel design
- [Core Contracts](../03-contracts/core-contracts.md) - Capability contracts and behaviours
- [BEAM Philosophy](../02-philosophy/beam-philosophy.md) - Defensive programming principles

**Prerequisites:**

- `arbor_security` application exists with basic structure
- Production persistence layer operational
- Basic capability contracts defined

**Core Security Implementation:**

```elixir
# apps/arbor_security/lib/arbor/security/kernel.ex
defmodule Arbor.Security.Kernel do
  @moduledoc """
  Central security authority implementing capability-based access control.
  """
  
  use GenServer
  require Logger
  
  alias Arbor.Contracts.Core.Capability
  alias Arbor.Security.{CapabilityStore, AuditLogger, Validator}
  
  # Public API matching specification
  def grant_capability(agent_id, resource_uri, operation, constraints \\ %{}) do
    GenServer.call(__MODULE__, {:grant, agent_id, resource_uri, operation, constraints})
  end
  
  def validate_capability(capability_id) do
    GenServer.call(__MODULE__, {:validate, capability_id})
  end
  
  def revoke_capability(capability_id, reason \\ :manual) do
    GenServer.call(__MODULE__, {:revoke, capability_id, reason})
  end
  
  # Implement full lifecycle management with process monitoring
end
```

**Postrequisites:**

- Zero-trust security model fully operational
- Capability inheritance and delegation working
- Automatic revocation on process termination
- Security audit trail complete
- Resource adapters functional

---

### Step 3: Enable Distributed Operation with Horde (TDD Approach)

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/01-overview/architecture-overview.md` - Review 'Distributed by Default' principle
- Step 0 contracts: `Arbor.Contracts.Cluster.Registry` and `Arbor.Contracts.Cluster.Supervisor` behaviors
- `docs/arbor/06-infrastructure/tooling-analysis.md` - Review Horde and libcluster patterns

BEFORE STARTING: Verify prerequisites are met - confirm Step 0 cluster contracts are frozen, persistence and security layers are operational, and `arbor_core` application exists.

Use layered test-driven development to implement distributed operation:

## PHASE A: UNIT TDD (Red-Green-Refactor)

Write failing unit tests for distributed coordination contracts:

1. **Test Agent Registry Logic:**
   ```elixir
   defmodule Arbor.Core.RegistryTest do
     test "registers agent with unique ID" do
       agent_id = "agent-123"
       # MOCK: Use local registry for unit testing
       assert :ok = ClusterRegistry.register_agent(agent_id, self())
       assert {:ok, pid} = ClusterRegistry.lookup_agent(agent_id)
       assert pid == self()
     end
     
     test "prevents duplicate agent registration" do
       agent_id = "agent-123"
       :ok = ClusterRegistry.register_agent(agent_id, self())
       assert {:error, :already_registered} = ClusterRegistry.register_agent(agent_id, self())
     end
   end
   ```

2. **Test Agent Supervision Logic:**
   Unit test agent lifecycle management:
   - Agent startup across cluster nodes
   - Agent termination and cleanup
   - Agent migration between nodes

3. **Test Cluster Coordination:**
   - Unit test node join/leave event handling
   - Test agent redistribution logic
   - Verify cluster state synchronization

Use **MOCK IMPLEMENTATIONS** from Step 0 for single-node testing without real clustering.

## PHASE B: INTEGRATION TDD

4. **Write Failing Multi-Node Integration Test:**
   ```elixir
   defmodule Arbor.Core.ClusterIntegrationTest do
     use ExUnit.Case
     @moduletag :integration
     @moduletag :cluster
     
     test "agents communicate across cluster nodes" do
       # This test will initially fail - requires real clustering
       
       # Start agents on different nodes
       {:ok, agent1_id} = ClusterSupervisor.start_agent(:worker, %{node: :node1})
       {:ok, agent2_id} = ClusterSupervisor.start_agent(:coordinator, %{node: :node2})
       
       # Verify agents are on different nodes
       {:ok, agent1_pid} = ClusterRegistry.lookup_agent(agent1_id)
       {:ok, agent2_pid} = ClusterRegistry.lookup_agent(agent2_id)
       assert node(agent1_pid) != node(agent2_pid)
       
       # Test cross-node communication
       :ok = AgentCoordinator.delegate_task(agent1_id, agent2_id, %{task_type: :analyze})
       
       # Verify task delegation across nodes
       assert_receive {:task_completed, ^agent2_id, result}, 5000
     end
     
     test "handles node failure with agent migration" do
       # Start agent on node1
       {:ok, agent_id} = ClusterSupervisor.start_agent(:worker, %{})
       original_node = get_agent_node(agent_id)
       
       # Simulate node failure
       disconnect_node(original_node)
       
       # Verify agent migrates to surviving node
       :timer.sleep(1000)  # Allow migration time
       {:ok, new_pid} = ClusterRegistry.lookup_agent(agent_id)
       assert node(new_pid) != original_node
     end
   end
   ```

5. **Implement Production Components:**
   - Add `horde` and `libcluster` dependencies
   - Configure `Arbor.Core.HordeRegistry` for distributed agent registration
   - Implement `Arbor.Core.HordeSupervisor` for distributed agent supervision
   - Add `libcluster` configuration for node discovery
   - Update Gateway and SessionManager for location transparency
   - Implement ClusterManager for node lifecycle events

6. **Integration Test Passes:**
   Use real multi-node setup (via Docker or distributed test framework)

## TESTING REQUIREMENTS

- **Unit Tests:** Test distributed logic with single-node mocks
- **Multi-Node Tests:** Test actual clustering with multiple BEAM nodes
- **Failure Tests:** Test node disconnection and agent migration scenarios
- **Performance Tests:** Verify clustering doesn't degrade single-node performance

## MOCK USAGE (CLEARLY LABELED)

Use these **MOCK IMPLEMENTATIONS** for unit testing:
- `Arbor.Test.Mocks.LocalRegistry` for single-node testing
- `Arbor.Test.Mocks.LocalSupervisor` for non-distributed testing
- Mark all mock usage: `# MOCK: Replace with Horde for distributed operation`

## DISTRIBUTED TESTING PATTERNS

Test distributed scenarios:
- **Node Discovery:** Nodes find each other automatically
- **Agent Distribution:** Agents spread across available nodes
- **Communication:** Agents can message across nodes
- **Failover:** Agents migrate when nodes fail
- **Split-Brain:** Cluster handles network partitions gracefully

AFTER COMPLETION: Verify postrequisites are achieved - multi-node cluster formation verified, agents distributed across nodes, cross-node communication working, automatic failover tested, and all distributed mocks clearly labeled."

**Reference Documentation:**

- [Architecture Overview](../01-overview/architecture-overview.md) - Distributed system principles
- [Arbor Core Specification](../04-components/arbor-core/specification.md) - Supervision tree with Horde
- [Tooling Analysis](../06-infrastructure/tooling-analysis.md) - Horde and libcluster recommendations
- [Communication Patterns](../05-architecture/communication-patterns.md) - Inter-node communication

**Prerequisites:**

- `arbor_core` application functional
- Persistence and security layers operational
- Basic agent management working

**Dependencies to Add:**

```elixir
# In apps/arbor_core/mix.exs
defp deps do
  [
    {:arbor_contracts, in_umbrella: true},
    {:arbor_security, in_umbrella: true},
    {:arbor_persistence, in_umbrella: true},
    {:horde, "~> 0.8"},
    {:libcluster, "~> 3.3"},
    {:phoenix_pubsub, "~> 2.1"},
    {:telemetry, "~> 1.0"}
  ]
end
```

**Cluster Configuration:**

```elixir
# In config/dev.exs
config :libcluster,
  topologies: [
    arbor_dev: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_addr: "230.1.1.251",
        multicast_ttl: 1,
        secret: "arbor_cluster_secret"
      ]
    ]
  ]
```

**Postrequisites:**

- Multi-node cluster operation verified
- Distributed agent registry functional
- Automatic failover on node loss
- Session continuity across cluster changes
- Cluster health monitoring active

---

### Step 4: Build Phoenix LiveView Web Dashboard

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/05-architecture/integration-patterns.md` - Study the Web Client Integration pattern and real-time update flow
- `docs/arbor/04-components/arbor-core/gateway-patterns.md` - Review event-driven updates and PubSub integration
- `docs/arbor/06-infrastructure/observability.md` - Understand monitoring requirements for the dashboard

BEFORE STARTING: Verify prerequisites are met - confirm `arbor_core` Gateway is functional with event publishing, persistence and security layers are operational, and distributed operation is working.

Create a new Phoenix application within the umbrella for the web dashboard, implementing real-time monitoring and control capabilities:

1. Generate new Phoenix app: `cd apps && mix phx.new arbor_web --umbrella --no-ecto`
2. Add necessary dependencies:
   - `phoenix_live_view` for real-time UI
   - `phoenix_live_dashboard` for system monitoring
   - `bandit` as the HTTP server
3. Configure WebSocket connections and Phoenix channels:
   - Create `ArborWeb.UserSocket` for authenticated connections
   - Implement `ArborWeb.SessionChannel` for session-specific communication
   - Connect to Phoenix.PubSub topics from `arbor_core`
4. Implement main dashboard LiveView components:
   - `ArborWeb.DashboardLive` - Overall system status and cluster health
   - `ArborWeb.SessionsLive` - Active sessions with real-time updates
   - `ArborWeb.AgentsLive` - Agent status, performance, and lifecycle
   - `ArborWeb.SecurityLive` - Capability monitoring and audit logs
   - `ArborWeb.ClusterLive` - Node status and distributed operations
5. Create interactive controls:
   - Session creation and management
   - Agent spawn/terminate controls
   - Capability grant/revoke interface
   - Emergency cluster operations
6. Implement real-time updates using Phoenix.PubSub:
   - Subscribe to relevant topics in LiveView mount
   - Handle events from Gateway, SecurityKernel, and ClusterManager
   - Update UI without page reloads
7. Add authentication and session management
8. Style with Tailwind CSS for professional appearance

Ensure all operations go through the `arbor_core` Gateway for proper security and auditing.

AFTER COMPLETION: Verify postrequisites are achieved - confirm web dashboard displays real-time system status, users can create sessions and manage agents through UI, security events are visible in audit interface, cluster status updates in real-time, and all operations are properly authenticated and authorized."

**Reference Documentation:**

- [Integration Patterns](../05-architecture/integration-patterns.md) - Web client integration pattern
- [Gateway Patterns](../04-components/arbor-core/gateway-patterns.md) - Event-driven updates
- [Observability](../06-infrastructure/observability.md) - Monitoring requirements

**Prerequisites:**

- `arbor_core` Gateway functional with events
- Persistence and security layers operational
- Distributed operation working

**Phoenix App Creation:**

```bash
# Create Phoenix app in umbrella
cd apps
mix phx.new arbor_web --umbrella --no-ecto
cd ..

# Add to umbrella supervision in mix.exs
```

**Dependencies to Add:**

```elixir
# In apps/arbor_web/mix.exs
defp deps do
  [
    {:arbor_core, in_umbrella: true},
    {:phoenix, "~> 1.7"},
    {:phoenix_live_view, "~> 0.20"},
    {:phoenix_live_dashboard, "~> 0.8"},
    {:bandit, "~> 1.0"},
    {:tailwind, "~> 0.2", only: :dev}
  ]
end
```

**Postrequisites:**

- Real-time web dashboard operational
- Session and agent management through UI
- Security monitoring interface active
- Cluster status visible and interactive
- Professional UI with proper authentication

---

### Step 5: Implement Application Observability Instrumentation

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/06-infrastructure/observability.md` - Study the complete three-pillar observability strategy (metrics, logs, traces)
- `docs/arbor/03-contracts/core-contracts.md` - Review telemetry event definitions and logging requirements
- `docs/arbor/02-philosophy/beam-philosophy.md` - Understand defensive monitoring principles

BEFORE STARTING: Verify prerequisites are met - confirm all core applications are implemented and functional, distributed operation is working, web dashboard is operational, and the existing Docker observability stack (Prometheus, Grafana, Jaeger) from Phase 1 is available.

Implement comprehensive observability instrumentation across all Arbor applications to leverage the existing observability infrastructure:

1. Add OpenTelemetry and monitoring dependencies to root `mix.exs`:
   - `opentelemetry`, `opentelemetry_api`, `opentelemetry_exporter`
   - `telemetry_metrics`, `telemetry_poller`
   - `logger_json` for structured logging

2. Create `Arbor.Telemetry` application for centralized observability:
   - `Arbor.Telemetry.Metrics` - Define all system metrics
   - `Arbor.Telemetry.Logger` - Structured logging handler
   - `Arbor.Telemetry.Tracer` - Distributed tracing setup

3. Instrument all applications with telemetry events:
   - Agent lifecycle events (spawn, terminate, error)
   - Security operations (grant, validate, revoke)
   - Persistence operations (read, write, recovery)
   - Cluster events (join, leave, migration)
   - Gateway operations (session create, message route)

4. Implement custom metrics for business logic:
   - Agent performance and execution time
   - Capability grant/deny ratios
   - Session duration and message counts
   - Cluster node health and distribution
   - Database operation latencies

5. Configure structured JSON logging:
   - Include correlation IDs for request tracing
   - Log security events with appropriate detail
   - Add contextual metadata for debugging
   - Implement log sampling for high-volume events

6. Set up distributed tracing:
   - Trace spans across node boundaries
   - Correlate traces with logs and metrics
   - Include custom attributes for business context

7. Configure integration with existing observability stack:
   - Prometheus metrics export endpoint
   - Jaeger tracing export to existing container
   - Log forwarding to Elasticsearch container

8. Create Grafana dashboards for Arbor-specific metrics:
   - System health and performance dashboards
   - Security and capability monitoring
   - Agent and session analytics

Include comprehensive error tracking and alerting configuration that integrates with the existing infrastructure.

AFTER COMPLETION: Verify postrequisites are achieved - confirm metrics are exported and visible in existing Prometheus, structured logs are generated with correlation IDs, distributed traces show cross-node operations in existing Jaeger, custom Grafana dashboards display Arbor-specific metrics, and alerting triggers on error conditions."

**Reference Documentation:**

- [Observability](../06-infrastructure/observability.md) - Three-pillar observability strategy
- [Core Contracts](../03-contracts/core-contracts.md) - Telemetry definitions
- [BEAM Philosophy](../02-philosophy/beam-philosophy.md) - Defensive monitoring

**Prerequisites:**

- All core applications functional
- Distributed operation working
- Web dashboard operational

**Dependencies to Add:**

```elixir
# In root mix.exs
defp deps do
  [
    # Existing deps...
    {:opentelemetry, "~> 1.3"},
    {:opentelemetry_api, "~> 1.2"},
    {:opentelemetry_exporter, "~> 1.6"},
    {:telemetry_metrics, "~> 0.6"},
    {:telemetry_poller, "~> 1.0"},
    {:logger_json, "~> 5.1"}
  ]
end
```

**Telemetry Configuration:**

```elixir
# In config/config.exs
config :opentelemetry, 
  service_name: "arbor",
  service_version: "0.1.0"

config :opentelemetry, :processors,
  otel_batch_processor: %{
    exporter: :otel_exporter_otlp
  }

config :opentelemetry_exporter,
  otlp_endpoint: "http://localhost:14250",
  otlp_headers: []
```

**Postrequisites:**

- Prometheus metrics collection active
- Grafana dashboards showing system health
- Distributed tracing with correlation
- Structured logging with context
- Alert conditions properly configured

---

### Step 6: Agent Implementation Framework

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/05-architecture/agent-architecture.md` - Study the agent lifecycle and behavior patterns
- `docs/arbor/03-contracts/core-contracts.md` - Review the Agent behaviour and Tool behaviour specifications
- `docs/arbor/04-components/arbor-core/specification.md` - Understand agent supervision and management

BEFORE STARTING: Verify prerequisites are met - confirm all previous steps are complete, distributed operation is stable, and security system is functional.

Implement the agent framework that allows for dynamic agent creation and management with proper lifecycle control:

1. Complete the `Arbor.Agent` behaviour in `arbor_contracts`:
   - Define required callbacks for agent lifecycle
   - Specify message handling patterns
   - Include capability requirement declarations
2. Implement `Arbor.Core.AgentFactory` for dynamic agent creation:
   - Support for different agent types
   - Proper capability assignment
   - Integration with security system
3. Create base agent implementations:
   - `Arbor.Agents.Worker` - General purpose task execution
   - `Arbor.Agents.Coordinator` - Multi-agent coordination
   - `Arbor.Agents.Monitor` - System monitoring and health checks
4. Implement `Arbor.Core.AgentPool` for resource management:
   - Pool warm agents for quick assignment
   - Load balancing across nodes
   - Resource limit enforcement
5. Create agent communication framework:
   - Message routing between agents
   - Event propagation patterns
   - Error handling and supervision
6. Add agent persistence integration:
   - State checkpointing
   - Recovery after failures
   - Long-term memory capabilities
7. Implement tool integration system:
   - Dynamic tool loading
   - Capability-based tool access
   - Tool result caching
8. Add comprehensive agent monitoring:
   - Performance metrics
   - Resource utilization
   - Error rates and patterns

Ensure all agents follow the defensive programming principles and integrate properly with the security and observability systems.

AFTER COMPLETION: Verify postrequisites are achieved - confirm different agent types can be created dynamically, agents communicate reliably across cluster nodes, agent state persists across restarts, capability system controls agent access to resources, and monitoring provides visibility into agent behavior."

**Reference Documentation:**

- [Agent Architecture](../05-architecture/agent-architecture.md) - Agent lifecycle and patterns
- [Core Contracts](../03-contracts/core-contracts.md) - Agent and Tool behaviours
- [Arbor Core Specification](../04-components/arbor-core/specification.md) - Agent management

**Prerequisites:**

- All previous steps completed
- Distributed operation stable
- Security system functional

**Agent Behaviour Implementation:**

```elixir
# apps/arbor_contracts/lib/arbor/agent.ex
defmodule Arbor.Agent do
  @moduledoc """
  Behaviour for all Arbor agents.
  """
  
  @type agent_id :: String.t()
  @type message :: term()
  @type state :: term()
  
  @callback init(params :: map()) :: {:ok, state} | {:error, term()}
  @callback handle_message(message, state) :: {:ok, state} | {:error, term()}
  @callback handle_capability_grant(capability :: term(), state) :: {:ok, state}
  @callback terminate(reason :: term(), state) :: :ok
  
  @optional_callbacks [handle_capability_grant: 2]
end
```

**Postrequisites:**

- Dynamic agent creation operational
- Agent communication across nodes reliable
- Agent state persistence working
- Capability-based resource access enforced
- Agent monitoring and metrics active

---

### Step 7: Integration Testing and Validation

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/06-infrastructure/observability.md` - Review testing and validation requirements
- `docs/arbor/02-philosophy/beam-philosophy.md` - Understand defensive testing principles

BEFORE STARTING: Verify prerequisites are met - confirm all Phase 2 components are implemented and individually functional.

Create comprehensive integration tests that validate the complete system functionality across all components:

1. Create integration test modules in each application:
   - `test/integration/` directories in each app
   - Multi-node test setup with dynamic clustering
   - Database setup/teardown for persistence tests
2. Implement end-to-end test scenarios:
   - Complete agent lifecycle from spawn to termination
   - Multi-agent coordination across cluster nodes
   - Session management with real-time web updates
   - Security policy enforcement under load
   - Disaster recovery and data consistency
3. Create performance and load tests:
   - Agent spawn/termination throughput
   - Message routing latency across nodes
   - Database performance under concurrent load
   - Memory usage patterns during operation
4. Implement chaos engineering tests:
   - Random node failures and recovery
   - Network partition handling
   - Database connection failures
   - High memory/CPU conditions
5. Create monitoring validation tests:
   - Verify all telemetry events are emitted
   - Confirm metrics accuracy
   - Validate log correlation
   - Test alerting conditions
6. Add system health checks:
   - Cluster health validation
   - Database connectivity and performance
   - Security system integrity
   - Web dashboard responsiveness
7. Create automated test scenarios:
   - CI pipeline integration tests
   - Nightly comprehensive test runs
   - Performance regression detection
8. Document test procedures and expected outcomes

Focus on validating the distributed, fault-tolerant, and secure operation that defines Arbor's value proposition.

AFTER COMPLETION: Verify postrequisites are achieved - confirm all integration tests pass consistently, system handles failures gracefully, performance meets requirements, monitoring captures all relevant events, and automated testing provides confidence in system reliability."

**Reference Documentation:**

- [Observability](../06-infrastructure/observability.md) - Testing and validation requirements
- [BEAM Philosophy](../02-philosophy/beam-philosophy.md) - Defensive testing principles

**Prerequisites:**

- All Phase 2 components implemented
- Individual functionality verified

**Integration Test Structure:**

```elixir
# test/integration/full_system_test.exs
defmodule Arbor.Integration.FullSystemTest do
  use ExUnit.Case, async: false
  
  @moduletag :integration
  @moduletag timeout: 60_000
  
  setup_all do
    # Setup multi-node cluster
    # Initialize database
    # Start observability stack
  end
  
  test "complete agent lifecycle with persistence" do
    # Create session
    # Spawn agents on different nodes
    # Execute tasks with capability requirements
    # Verify state persistence
    # Simulate node failure
    # Verify recovery and migration
  end
end
```

**Postrequisites:**

- Comprehensive integration test coverage
- Chaos engineering validation
- Performance benchmarks established
- Monitoring validation automated
- System reliability demonstrated

---

## Workflow Diagram

```text
    Phase 1 MVP Complete
            |
            v
    [Step 1: Production Persistence]
            |
            v
    [Step 2: Security System]
            |
            v
    [Step 3: Distributed Operation]
            |
            v
    [Step 4: Web Dashboard]
            |
            v
    [Step 5: Observability Stack]
            |
            v
    [Step 6: Agent Framework]
            |
            v
    [Step 7: Integration Testing]
            |
            v
    Production-Ready System
```

## Success Criteria

Phase 2 completion will be measured by these concrete outcomes:

### Technical Capabilities

- [ ] System survives PostgreSQL database restarts without data loss
- [ ] Agents continue operation during cluster node failures
- [ ] Web dashboard shows real-time updates without page refreshes
- [ ] Security capabilities are automatically revoked on process termination
- [ ] Distributed traces correlate operations across multiple nodes
- [ ] Agent state persists and recovers after complete system restart

### Performance Targets

- [ ] Agent spawn time < 100ms on local cluster
- [ ] Message routing latency < 10ms within cluster
- [ ] Database operations < 50ms for typical queries
- [ ] Web dashboard updates < 500ms for state changes
- [ ] Memory usage stable during 24-hour operation
- [ ] No memory leaks during agent lifecycle stress tests

### Operational Requirements

- [ ] Complete observability through metrics, logs, and traces
- [ ] Automated integration tests passing in CI
- [ ] Documentation complete for all new components
- [ ] Development setup reproducible with provided scripts
- [ ] Production deployment ready with Docker containers

## Risk Mitigation

### Technical Risks

1. **Database Performance**: Implement connection pooling and query optimization early
2. **Cluster Split-Brain**: Use proper quorum and partition tolerance strategies
3. **Memory Leaks**: Extensive process monitoring and automatic garbage collection
4. **Security Vulnerabilities**: Comprehensive capability validation and audit logging

### Development Risks

1. **Complexity Overload**: Implement incrementally with validation at each step
2. **Integration Failures**: Continuous integration testing throughout development
3. **Performance Regressions**: Automated performance testing and monitoring

## Summary

Phase 2 transforms Arbor from an architectural skeleton into a production-ready distributed system. This implementation plan provides:

1. **Incremental Development**: Each step builds on previous achievements
2. **Comprehensive Testing**: Validation at every level from unit to integration
3. **Production Focus**: Real-world operational requirements addressed
4. **Risk Management**: Proactive identification and mitigation of potential issues

Each step includes detailed AI prompts that provide sufficient context and requirements for autonomous implementation, ensuring consistent quality and adherence to the architectural vision.

The successful completion of Phase 2 will deliver a robust, scalable, and secure distributed AI agent orchestration system ready for production workloads and future enhancement.
