# Priority 1.2: Persistent Security Layer - Implementation Plan

**Priority**: CRITICAL - Production Blocker
**Timeline**: 3 weeks (Weeks 2-4 of Phase 1)
**Owner**: Core Team
**Status**: NOT STARTED

---

## Executive Summary

This plan details the implementation of persistent storage for the security layer, replacing in-memory mocks with database-backed implementations. This is the **critical blocker** preventing production deployment.

**Problem**: CapabilityStore and AuditLogger currently use in-memory storage, losing all data on restart.

**Solution**: Implement PostgreSQL-backed persistence using Ecto for both components.

**Impact**: Unblocks production deployment, enables compliance, prevents data loss.

---

## Current State Analysis

### What Exists Now

**CapabilityStore** (`apps/arbor_security/lib/arbor/security/capability_store.ex`):
```elixir
# Lines 343-359: Mock PostgreSQL module
defmodule PostgresDB do
  @moduledoc """
  Mock PostgreSQL database module for testing.

  TODO: This is a mock implementation for testing only!
  FIXME: All data is lost on restart - not suitable for production use!
  """

  use Agent  # In-memory storage

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{capabilities: %{}, sequence: 0} end, name: __MODULE__)
  end

  # CRUD operations using Agent
end
```

**Issues**:
- ❌ All capability data lost on restart
- ❌ No persistence across deployments
- ❌ Cannot audit capability grants/revokes historically
- ❌ No transaction support

**AuditLogger** (`apps/arbor_security/lib/arbor/security/audit_logger.ex`):
```elixir
# Lines 330-346: Mock PostgreSQL module
defmodule PostgresDB do
  @moduledoc """
  Mock PostgreSQL database module for audit events.

  TODO: This is a mock implementation for testing only!
  FIXME: All audit events are lost on restart - non-compliant for production!
  """

  use Agent  # In-memory storage

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{events: [], sequence: 0} end, name: __MODULE__)
  end

  # CRUD operations using Agent
end
```

**Issues**:
- ❌ All audit events lost on restart
- ❌ Compliance violation (audit trails must be immutable)
- ❌ Cannot query historical events
- ❌ No batch insert for performance

### Dependencies

**Ecto Configuration** (already exists):
```elixir
# apps/arbor_security/mix.exs
{:ecto_sql, "~> 3.10"},
{:postgrex, ">= 0.0.0"}
```

**Database Configuration** (may need to add):
```elixir
# config/dev.exs, config/test.exs, config/prod.exs
config :arbor_security, Arbor.Security.Repo,
  database: "arbor_security_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost"
```

---

## Database Schema Design

### Capabilities Table

**Purpose**: Store capability grants with metadata and expiration

```elixir
# Table: capabilities
create table(:capabilities) do
  add :capability_id, :string, null: false  # Unique capability identifier
  add :resource_type, :string, null: false  # e.g., "agent", "session"
  add :resource_id, :string, null: false    # Specific resource ID
  add :action, :string, null: false         # e.g., "read", "write", "execute"
  add :granted_to, :string, null: false     # Subject receiving capability
  add :granted_by, :string, null: false     # Subject granting capability
  add :granted_at, :utc_datetime_usec, null: false
  add :expires_at, :utc_datetime_usec      # Nullable for permanent capabilities
  add :revoked, :boolean, default: false, null: false
  add :revoked_at, :utc_datetime_usec
  add :revoked_by, :string
  add :metadata, :map, default: %{}        # JSON metadata

  timestamps(type: :utc_datetime_usec)
end

# Indexes for performance
create unique_index(:capabilities, [:capability_id])
create index(:capabilities, [:resource_type, :resource_id])
create index(:capabilities, [:granted_to])
create index(:capabilities, [:expires_at])
create index(:capabilities, [:revoked])

# Composite index for common queries
create index(:capabilities, [:granted_to, :revoked, :expires_at])
```

**Estimated Size**:
- Row size: ~500 bytes (with metadata)
- Expected rows: 10K-100K capabilities
- Disk space: ~50MB for 100K capabilities

### Audit Events Table

**Purpose**: Immutable audit log of all security-related events

```elixir
# Table: audit_events
create table(:audit_events) do
  add :event_id, :string, null: false       # Unique event identifier
  add :event_type, :string, null: false     # e.g., "capability_granted", "capability_revoked"
  add :actor, :string, null: false          # Who performed the action
  add :target, :string                      # What was acted upon
  add :action, :string, null: false         # What action was taken
  add :result, :string, null: false         # "success", "failure"
  add :reason, :string                      # Failure reason if applicable
  add :ip_address, :string                  # Source IP
  add :user_agent, :string                  # User agent if applicable
  add :metadata, :map, default: %{}         # JSON metadata
  add :occurred_at, :utc_datetime_usec, null: false

  timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
end

# Indexes for audit queries
create unique_index(:audit_events, [:event_id])
create index(:audit_events, [:event_type])
create index(:audit_events, [:actor])
create index(:audit_events, [:occurred_at])
create index(:audit_events, [:result])

# Composite index for common audit queries
create index(:audit_events, [:event_type, :occurred_at])
create index(:audit_events, [:actor, :occurred_at])
```

**Estimated Size**:
- Row size: ~600 bytes (with metadata)
- Expected rows: 100K-1M events per month
- Disk space: ~600MB per month
- **Recommendation**: Implement archival strategy after 90 days

---

## Implementation Plan

### Week 1: CapabilityStore Persistence

#### Day 1-2: Database Setup & Schema

**Tasks**:
1. Create Ecto Repo for arbor_security
2. Create migration for capabilities table
3. Create Capability schema module
4. Configure database connections

**Files to Create**:
```
apps/arbor_security/lib/arbor/security/repo.ex
apps/arbor_security/lib/arbor/security/persistence/schemas/capability.ex
apps/arbor_security/priv/repo/migrations/20251118_create_capabilities.exs
```

**Capability Schema**:
```elixir
defmodule Arbor.Security.Persistence.Schemas.Capability do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "capabilities" do
    field :capability_id, :string
    field :resource_type, :string
    field :resource_id, :string
    field :action, :string
    field :granted_to, :string
    field :granted_by, :string
    field :granted_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked, :boolean, default: false
    field :revoked_at, :utc_datetime_usec
    field :revoked_by, :string
    field :metadata, :map

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:capability_id, :resource_type, :resource_id, :action,
                    :granted_to, :granted_by, :granted_at]
  @optional_fields [:expires_at, :revoked, :revoked_at, :revoked_by, :metadata]

  def changeset(capability, attrs) do
    capability
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:capability_id)
    |> validate_expiration()
  end

  defp validate_expiration(changeset) do
    # Ensure expires_at is in the future if present
    case get_field(changeset, :expires_at) do
      nil -> changeset
      expires_at ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          changeset
        else
          add_error(changeset, :expires_at, "must be in the future")
        end
    end
  end
end
```

#### Day 3-4: CapabilityRepo Implementation

**File to Create**:
```
apps/arbor_security/lib/arbor/security/persistence/capability_repo.ex
```

**CapabilityRepo Module**:
```elixir
defmodule Arbor.Security.Persistence.CapabilityRepo do
  @moduledoc """
  Repository for capability persistence operations.

  Provides CRUD operations for capabilities with transaction support.
  """

  import Ecto.Query
  alias Arbor.Security.Repo
  alias Arbor.Security.Persistence.Schemas.Capability

  @doc "Create a new capability"
  @spec create_capability(map()) :: {:ok, Capability.t()} | {:error, Ecto.Changeset.t()}
  def create_capability(attrs) do
    %Capability{}
    |> Capability.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Get capability by ID"
  @spec get_capability(String.t()) :: {:ok, Capability.t()} | {:error, :not_found}
  def get_capability(capability_id) do
    case Repo.get_by(Capability, capability_id: capability_id) do
      nil -> {:error, :not_found}
      capability -> {:ok, capability}
    end
  end

  @doc "Get all active (non-revoked, non-expired) capabilities for a subject"
  @spec get_active_capabilities(String.t()) :: {:ok, [Capability.t()]}
  def get_active_capabilities(subject) do
    now = DateTime.utc_now()

    query = from c in Capability,
      where: c.granted_to == ^subject,
      where: c.revoked == false,
      where: is_nil(c.expires_at) or c.expires_at > ^now,
      order_by: [desc: c.granted_at]

    {:ok, Repo.all(query)}
  end

  @doc "Revoke a capability"
  @spec revoke_capability(String.t(), String.t()) :: {:ok, Capability.t()} | {:error, term()}
  def revoke_capability(capability_id, revoked_by) do
    Repo.transaction(fn ->
      case get_capability(capability_id) do
        {:ok, capability} ->
          capability
          |> Capability.changeset(%{
            revoked: true,
            revoked_at: DateTime.utc_now(),
            revoked_by: revoked_by
          })
          |> Repo.update!()

        {:error, :not_found} ->
          Repo.rollback(:not_found)
      end
    end)
  end

  @doc "Check if a capability is valid (exists, not revoked, not expired)"
  @spec valid_capability?(String.t()) :: boolean()
  def valid_capability?(capability_id) do
    now = DateTime.utc_now()

    query = from c in Capability,
      where: c.capability_id == ^capability_id,
      where: c.revoked == false,
      where: is_nil(c.expires_at) or c.expires_at > ^now,
      select: count(c.id)

    Repo.one(query) > 0
  end

  @doc "Cleanup expired capabilities (mark as revoked)"
  @spec cleanup_expired() :: {:ok, integer()}
  def cleanup_expired() do
    now = DateTime.utc_now()

    {count, _} = from(c in Capability,
      where: c.revoked == false,
      where: not is_nil(c.expires_at),
      where: c.expires_at <= ^now
    )
    |> Repo.update_all(set: [
      revoked: true,
      revoked_at: now,
      revoked_by: "system:expiration"
    ])

    {:ok, count}
  end
end
```

#### Day 5: Integration & Testing

**Tasks**:
1. Update CapabilityStore to use CapabilityRepo
2. Add fallback to mock for development if DB unavailable
3. Write unit tests for CapabilityRepo
4. Write integration tests for CapabilityStore
5. Test migration and rollback

**Files to Modify**:
```
apps/arbor_security/lib/arbor/security/capability_store.ex
```

**Integration Strategy**:
```elixir
defmodule Arbor.Security.CapabilityStore do
  # ... existing code ...

  # Replace PostgresDB.create_capability/1 calls with:
  defp persist_capability(capability) do
    case Arbor.Security.Persistence.CapabilityRepo.create_capability(capability) do
      {:ok, _stored} -> :ok
      {:error, changeset} ->
        Logger.error("Failed to persist capability: #{inspect(changeset)}")
        {:error, :persistence_failed}
    end
  end

  # Replace PostgresDB.get_capability/1 calls with:
  defp fetch_capability(capability_id) do
    Arbor.Security.Persistence.CapabilityRepo.get_capability(capability_id)
  end

  # Add cleanup job for expired capabilities
  def cleanup_expired_capabilities() do
    Arbor.Security.Persistence.CapabilityRepo.cleanup_expired()
  end
end
```

---

### Week 2: AuditLogger Persistence

#### Day 6-7: Audit Schema & Repo

**Files to Create**:
```
apps/arbor_security/lib/arbor/security/persistence/schemas/audit_event.ex
apps/arbor_security/lib/arbor/security/persistence/audit_repo.ex
apps/arbor_security/priv/repo/migrations/20251125_create_audit_events.exs
```

**AuditEvent Schema**:
```elixir
defmodule Arbor.Security.Persistence.Schemas.AuditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "audit_events" do
    field :event_id, :string
    field :event_type, :string
    field :actor, :string
    field :target, :string
    field :action, :string
    field :result, :string
    field :reason, :string
    field :ip_address, :string
    field :user_agent, :string
    field :metadata, :map
    field :occurred_at, :utc_datetime_usec

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @required_fields [:event_id, :event_type, :actor, :action, :result, :occurred_at]
  @optional_fields [:target, :reason, :ip_address, :user_agent, :metadata]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:result, ["success", "failure", "pending"])
    |> unique_constraint(:event_id)
  end
end
```

**AuditRepo Module**:
```elixir
defmodule Arbor.Security.Persistence.AuditRepo do
  @moduledoc """
  Repository for audit event persistence.

  Provides immutable audit log with batch insert support.
  """

  import Ecto.Query
  alias Arbor.Security.Repo
  alias Arbor.Security.Persistence.Schemas.AuditEvent

  @doc "Insert a single audit event"
  @spec insert_event(map()) :: {:ok, AuditEvent.t()} | {:error, Ecto.Changeset.t()}
  def insert_event(attrs) do
    %AuditEvent{}
    |> AuditEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Batch insert multiple audit events (for performance)"
  @spec insert_events([map()]) :: {:ok, integer()} | {:error, term()}
  def insert_events(events) when is_list(events) do
    now = DateTime.utc_now()

    entries = Enum.map(events, fn event ->
      event
      |> Map.put(:created_at, now)
      |> Map.put_new(:occurred_at, now)
    end)

    case Repo.insert_all(AuditEvent, entries, returning: false) do
      {count, _} -> {:ok, count}
      error -> {:error, error}
    end
  end

  @doc "Query audit events with filters"
  @spec query_events(map()) :: {:ok, [AuditEvent.t()]}
  def query_events(filters \\ %{}) do
    query = from e in AuditEvent, order_by: [desc: e.occurred_at]

    query = Enum.reduce(filters, query, fn
      {:event_type, type}, q -> where(q, [e], e.event_type == ^type)
      {:actor, actor}, q -> where(q, [e], e.actor == ^actor)
      {:result, result}, q -> where(q, [e], e.result == ^result)
      {:from, datetime}, q -> where(q, [e], e.occurred_at >= ^datetime)
      {:to, datetime}, q -> where(q, [e], e.occurred_at <= ^datetime)
      {:limit, limit}, q -> limit(q, ^limit)
      _, q -> q
    end)

    {:ok, Repo.all(query)}
  end

  @doc "Get audit events for a specific resource"
  @spec get_resource_audit_trail(String.t()) :: {:ok, [AuditEvent.t()]}
  def get_resource_audit_trail(resource_id) do
    query = from e in AuditEvent,
      where: e.target == ^resource_id or fragment("?->>'resource_id' = ?", e.metadata, ^resource_id),
      order_by: [desc: e.occurred_at]

    {:ok, Repo.all(query)}
  end
end
```

#### Day 8-9: Integration & Batch Processing

**Tasks**:
1. Update AuditLogger to use AuditRepo
2. Implement batch insert for performance
3. Add background worker for async audit logging
4. Configure buffering strategy

**Files to Modify**:
```
apps/arbor_security/lib/arbor/security/audit_logger.ex
```

**Integration with Batching**:
```elixir
defmodule Arbor.Security.AuditLogger do
  use GenServer

  # Buffer audit events and flush periodically
  @flush_interval 5_000  # 5 seconds
  @buffer_size 100        # Flush when buffer reaches 100 events

  def init(_opts) do
    schedule_flush()
    {:ok, %{buffer: [], timer: nil}}
  end

  def handle_cast({:log_event, event}, state) do
    buffer = [event | state.buffer]

    if length(buffer) >= @buffer_size do
      flush_buffer(buffer)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: buffer}}
    end
  end

  def handle_info(:flush, state) do
    if length(state.buffer) > 0 do
      flush_buffer(state.buffer)
    end

    schedule_flush()
    {:noreply, %{state | buffer: []}}
  end

  defp flush_buffer(events) do
    case Arbor.Security.Persistence.AuditRepo.insert_events(events) do
      {:ok, count} ->
        Logger.debug("Flushed #{count} audit events to database")
        :ok
      {:error, reason} ->
        Logger.error("Failed to flush audit events: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp schedule_flush() do
    Process.send_after(self(), :flush, @flush_interval)
  end
end
```

#### Day 10: Testing & Performance

**Tasks**:
1. Write unit tests for AuditRepo
2. Write integration tests for AuditLogger
3. Performance testing for batch inserts
4. Test query performance with indexes

**Performance Targets**:
- Single insert: <5ms
- Batch insert (100 events): <50ms
- Query with filters: <100ms
- Audit trail query: <200ms

---

### Week 3: Integration, Testing & Documentation

#### Day 11-12: End-to-End Integration

**Tasks**:
1. Test CapabilityStore + AuditLogger together
2. Test with Gateway operations
3. Test restart scenarios (data persistence)
4. Test concurrent operations
5. Test transaction rollback scenarios

**Integration Test Scenarios**:
```elixir
defmodule Arbor.SecurityIntegrationTest do
  use ExUnit.Case

  describe "capability grant and audit" do
    test "granting capability creates audit event" do
      # Grant capability
      {:ok, cap} = CapabilityStore.grant_capability(...)

      # Verify capability persisted
      {:ok, stored_cap} = CapabilityRepo.get_capability(cap.id)
      assert stored_cap.capability_id == cap.id

      # Verify audit event created
      {:ok, events} = AuditRepo.query_events(%{event_type: "capability_granted"})
      assert length(events) > 0
      assert Enum.any?(events, &(&1.target == cap.id))
    end

    test "capability survives restart" do
      # Grant capability
      {:ok, cap} = CapabilityStore.grant_capability(...)

      # Simulate restart by stopping and starting application
      :ok = Application.stop(:arbor_security)
      :ok = Application.start(:arbor_security)

      # Verify capability still exists
      assert CapabilityStore.has_capability?(cap.id)
    end
  end
end
```

#### Day 13-14: Security Review

**Tasks**:
1. Security audit of database access
2. SQL injection prevention review
3. Access control verification
4. Encryption at rest configuration
5. Audit trail immutability verification

**Security Checklist**:
- [ ] All queries use parameterized queries (Ecto protects against SQL injection)
- [ ] Audit events are append-only (no updates/deletes)
- [ ] Sensitive data in metadata is encrypted
- [ ] Database credentials stored securely
- [ ] Connection pooling configured properly
- [ ] Row-level security policies considered
- [ ] Backup strategy defined

#### Day 15: Documentation & Migration Guide

**Tasks**:
1. Update architecture documentation
2. Write migration guide from mock to persistent
3. Document database configuration
4. Create runbook for operations
5. Update deployment documentation

**Files to Create/Update**:
```
docs/security/PERSISTENT_SECURITY.md
docs/deployment/DATABASE_SETUP.md
docs/operations/BACKUP_RESTORE.md
```

**Migration Guide**:
```markdown
# Migrating to Persistent Security Layer

## Prerequisites
- PostgreSQL 12+ installed
- Database user with CREATE DATABASE privileges

## Steps

1. Create database:
   ```bash
   createdb arbor_security_dev
   createdb arbor_security_test
   ```

2. Run migrations:
   ```bash
   cd apps/arbor_security
   mix ecto.migrate
   ```

3. Verify schema:
   ```bash
   mix ecto.show_tables
   # Should show: capabilities, audit_events, schema_migrations
   ```

4. Test configuration:
   ```elixir
   iex> Arbor.Security.Repo.query!("SELECT 1")
   # Should return success
   ```

5. Update application configuration (if needed)

6. Restart application

## Rollback (if needed)
1. Stop application
2. Restore previous configuration
3. Restart with mock implementation
```

---

## Testing Strategy

### Unit Tests

**CapabilityRepo Tests** (`test/arbor/security/persistence/capability_repo_test.exs`):
```elixir
- create_capability/1 with valid data
- create_capability/1 with invalid data
- get_capability/1 existing and non-existing
- get_active_capabilities/1 with various states
- revoke_capability/2 success and failure
- valid_capability?/1 for various states
- cleanup_expired/0 functionality
```

**AuditRepo Tests** (`test/arbor/security/persistence/audit_repo_test.exs`):
```elixir
- insert_event/1 with valid/invalid data
- insert_events/1 batch insert
- query_events/1 with various filters
- get_resource_audit_trail/1
```

### Integration Tests

**CapabilityStore Integration** (`test/arbor/security/capability_store_integration_test.exs`):
```elixir
- Grant capability and verify persistence
- Revoke capability and verify in database
- Check capability after restart
- Concurrent capability operations
- Transaction rollback scenarios
```

**AuditLogger Integration** (`test/arbor/security/audit_logger_integration_test.exs`):
```elixir
- Log event and verify in database
- Batch logging performance
- Buffer flush behavior
- Concurrent logging
```

### Performance Tests

**Load Testing** (`test/arbor/security/performance_test.exs`):
```elixir
- 1000 capability grants in <5 seconds
- 10000 audit events in <30 seconds
- Query 100K capabilities in <1 second
- Concurrent operations (100 processes)
```

### Manual Testing

**Restart Scenario**:
1. Start application
2. Grant 10 capabilities
3. Log 100 audit events
4. Stop application
5. Start application
6. Verify all data persists
7. Query capabilities and audit trail

---

## Migration Strategy

### Development Environment

1. **Database Setup**:
   ```bash
   createdb arbor_security_dev
   cd apps/arbor_security
   mix ecto.migrate
   ```

2. **Configuration**:
   ```elixir
   # config/dev.exs
   config :arbor_security, Arbor.Security.Repo,
     database: "arbor_security_dev",
     username: "postgres",
     password: "postgres",
     hostname: "localhost",
     pool_size: 10
   ```

3. **Testing**:
   - Run test suite
   - Manual smoke testing
   - Performance testing

### Production Environment

1. **Pre-deployment**:
   - Backup existing data (even though it's in-memory)
   - Review database configuration
   - Test migrations on staging

2. **Deployment**:
   - Create production database
   - Run migrations
   - Deploy new code
   - Verify connectivity
   - Monitor for errors

3. **Post-deployment**:
   - Verify data persisting
   - Check audit trail
   - Monitor performance
   - Run health checks

### Rollback Plan

**If deployment fails**:

1. **Immediate Rollback** (< 5 minutes):
   ```bash
   # Revert to previous deployment
   git checkout <previous-commit>
   mix release
   ```

2. **Database Rollback** (if needed):
   ```bash
   cd apps/arbor_security
   mix ecto.rollback --step 2  # Rollback both migrations
   ```

3. **Configuration Rollback**:
   - Revert config changes
   - Restart with mock implementation

4. **Verification**:
   - Test capability operations
   - Test audit logging
   - Monitor for errors

---

## Success Criteria

### Functional Criteria

- [ ] CapabilityStore uses database persistence
- [ ] AuditLogger uses database persistence
- [ ] All existing tests pass
- [ ] New integration tests pass
- [ ] Data persists across restarts
- [ ] Concurrent operations work correctly
- [ ] Transactions rollback properly on errors

### Performance Criteria

- [ ] Capability grant: <10ms (p95)
- [ ] Capability check: <5ms (p95)
- [ ] Audit event insert: <5ms (p95)
- [ ] Batch audit insert (100): <50ms (p95)
- [ ] Capability query: <100ms (p95)
- [ ] Audit trail query: <200ms (p95)

### Security Criteria

- [ ] No SQL injection vulnerabilities
- [ ] Audit trail is immutable
- [ ] Sensitive data encrypted
- [ ] Access controls verified
- [ ] Security review completed
- [ ] Threat model updated

### Operational Criteria

- [ ] Database backup strategy defined
- [ ] Restore procedure documented
- [ ] Monitoring configured
- [ ] Alerting set up
- [ ] Runbook created
- [ ] Migration guide tested

---

## Risk Mitigation

### Risk 1: Migration Complexity
- **Probability**: Medium
- **Impact**: High (could delay timeline)
- **Mitigation**:
  - Start early with schema design
  - Test migrations thoroughly
  - Use staging environment
- **Contingency**: Extend Week 1 by 2-3 days if needed

### Risk 2: Performance Issues
- **Probability**: Low
- **Impact**: Medium
- **Mitigation**:
  - Design indexes upfront
  - Batch insert for audit events
  - Performance testing before deployment
- **Contingency**: Add caching layer if needed

### Risk 3: Data Loss During Migration
- **Probability**: Low (using in-memory currently)
- **Impact**: Low (no production data to lose)
- **Mitigation**:
  - Comprehensive testing
  - Rollback plan ready
- **Contingency**: Mock implementation still available

### Risk 4: Database Connection Issues
- **Probability**: Medium
- **Impact**: High
- **Mitigation**:
  - Connection pooling configured
  - Retry logic implemented
  - Fallback to mock in development
- **Contingency**: Implement circuit breaker pattern

---

## Monitoring & Observability

### Metrics to Track

**Database Metrics**:
- Connection pool utilization
- Query latency (p50, p95, p99)
- Transaction success rate
- Deadlock frequency
- Table sizes and growth rate

**Application Metrics**:
- Capability grant/revoke rate
- Audit event insertion rate
- Cache hit rate (if caching added)
- Error rate by operation

**Business Metrics**:
- Active capabilities count
- Audit events per day
- Capability expiration rate
- Security violation attempts

### Logging

**What to Log**:
- All database errors
- Slow queries (>100ms)
- Transaction rollbacks
- Batch flush operations
- Migration executions

**Log Levels**:
- ERROR: Database failures, transaction failures
- WARN: Slow queries, high connection pool usage
- INFO: Migration completion, batch flushes
- DEBUG: Individual operations (development only)

### Alerting

**Critical Alerts**:
- Database connection failures
- Transaction failure rate > 1%
- Query latency p95 > 500ms
- Audit event loss detected

**Warning Alerts**:
- Connection pool > 80% utilized
- Audit buffer flush delays
- Expired capability cleanup failures

---

## Dependencies & Prerequisites

### Required Before Starting

- [ ] PostgreSQL installed and running
- [ ] Ecto dependencies added to mix.exs
- [ ] Database configuration in config files
- [ ] Repo module exists
- [ ] Test database created

### Optional Enhancements

- [ ] Connection pooling optimized (DBConnection)
- [ ] Read replicas configured (future)
- [ ] Partitioning strategy for audit_events (future)
- [ ] Archival strategy for old audit events (future)

---

## Timeline Summary

| Week | Focus | Deliverables | Risk Level |
|------|-------|--------------|------------|
| Week 1 | CapabilityStore | Schema, Repo, Integration, Tests | Medium |
| Week 2 | AuditLogger | Schema, Repo, Batching, Tests | Medium |
| Week 3 | Integration | E2E tests, Security review, Docs | Low |

**Total Effort**: 3 weeks (15 working days)
**Buffer**: Week 3 has some slack for issues from Weeks 1-2

---

## Next Steps After Completion

Once Priority 1.2 is complete:

1. **Immediate**:
   - Move to Priority 1.3 (Agent Registration Stability)
   - Update project status documents
   - Announce persistent security completion

2. **Short-term** (Within 1 month):
   - Monitor production usage
   - Optimize based on real-world data
   - Implement archival if needed

3. **Medium-term** (Within 3 months):
   - Add read replicas if needed
   - Implement caching layer
   - Optimize indexes based on query patterns

---

## References

- [Ecto Documentation](https://hexdocs.pm/ecto/Ecto.html)
- [PostgreSQL Best Practices](https://wiki.postgresql.org/wiki/Don%27t_Do_This)
- [Arbor Security Architecture](../docs/arbor/04-components/arbor-security/specification.md)
- [Database Schema Design Guidelines](../docs/development.md)

---

**Status**: READY TO BEGIN
**Next Action**: Begin Week 1, Day 1 - Database Setup & Schema
**Checkpoint**: End of Week 1 - CapabilityStore working with database
