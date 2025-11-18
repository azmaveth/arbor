# Automated Testing Guide for Arbor Security Layer

**Last Updated**: November 18, 2025
**Status**: ✅ Fully Automated - Ready to Use

---

## Quick Start

### Run All Tests (Including Persistence Integration Tests)

```bash
# Development environment - Run integration tests
ARBOR_INTEGRATION=true mix test

# OR use the test script (recommended)
./scripts/test.sh --integration
```

That's it! The test suite will:
1. ✅ Automatically create the test database
2. ✅ Automatically run migrations
3. ✅ Clean the database between tests
4. ✅ Run all 644 lines of comprehensive integration tests
5. ✅ Test persistence, caching, audit logging, and more

---

## What's Already Automated

### ✅ Comprehensive Integration Test Suite

**File**: `apps/arbor_security/test/arbor/security/integration_test.exs`

**Coverage** (644 lines):
- Complete capability lifecycle with PostgreSQL persistence
- Write-through cache validation (ETS + PostgreSQL)
- Capability delegation with cascade revocation
- Process monitoring and automatic revocation
- Telemetry event emission
- Performance under concurrent load (15 operations)
- Error handling and edge cases
- Database connection failures
- Malformed data handling
- Resource URI validation

### ✅ Automatic Database Management

**Function**: `ensure_database_ready()` (lines 559-575)

Automatically:
1. Starts the PostgreSQL Repo
2. Runs all migrations from `priv/repo/migrations/`
3. Creates `capabilities` and `audit_events` tables
4. Creates all indexes for performance
5. Handles errors gracefully (continues if DB unavailable)

**Function**: `clean_database_tables()` (lines 577-591)

Automatically:
- Cleans capabilities table before each test
- Cleans audit_events table before each test
- Ensures test isolation

### ✅ Test Environment Detection

**File**: `apps/arbor_security/test/test_helper.exs`

Automatically detects:
- **Watch Mode**: `TEST_WATCH=true` (runs only fast tests)
- **CI Mode**: `CI=true` (runs all except chaos/distributed)
- **Integration Mode**: Runs when not excluded
- **Distributed Mode**: `ARBOR_DISTRIBUTED_TEST=true`

---

## Running Tests

### 1. Run Fast Unit Tests (Default)

```bash
mix test
```

**Excluded**: Integration, distributed, chaos tests
**Duration**: ~30 seconds
**Uses**: Mock databases (no PostgreSQL needed)

### 2. Run Integration Tests (Including Persistence)

```bash
# Method 1: Environment variable
ARBOR_INTEGRATION=true mix test

# Method 2: Explicit tag
mix test --include integration

# Method 3: Only integration tests
mix test --only integration

# Method 4: Using test script
./scripts/test.sh --integration
```

**Included**: All tests including database persistence
**Duration**: ~2-3 minutes
**Requires**: PostgreSQL running on localhost:5432
**Database**: `arbor_security_test` (auto-created)

### 3. Run Specific Persistence Tests

```bash
# Run the entire integration test file
mix test apps/arbor_security/test/arbor/security/integration_test.exs

# Run specific test
mix test apps/arbor_security/test/arbor/security/integration_test.exs:63

# Run with detailed output
mix test apps/arbor_security/test/arbor/security/integration_test.exs --trace
```

### 4. Run All Tests (Full Suite)

```bash
# Everything except chaos and distributed
CI=true mix test

# Absolutely everything (slow)
mix test --include integration --include distributed --include chaos
```

---

## Test Scenarios Covered

### ✅ Capability Lifecycle with Persistence (Test: line 63)

**What it tests**:
1. Grant capability through Security.Kernel
2. Verify stored in PostgreSQL (via CapabilityStore)
3. Verify cached in ETS (sub-millisecond reads)
4. Authorize using the capability
5. Verify audit events persisted
6. Revoke capability
7. Verify revocation persisted and cached invalidated

**Validates**:
- PostgreSQL write-through cache pattern works
- ETS cache provides fast reads
- Audit events survive restarts
- Revocation is durable

### ✅ Delegation with Cascade Revocation (Test: line 148)

**What it tests**:
1. Grant parent capability
2. Delegate to child agent
3. Verify both capabilities work
4. Revoke parent with cascade flag
5. Verify child automatically revoked
6. Verify cascade audit trail

**Validates**:
- Delegation depth tracking in database
- Cascade revocation traverses hierarchy
- All revocations audited

### ✅ Process Monitoring (Test: line 222)

**What it tests**:
1. Grant capability tied to agent process
2. Verify capability works
3. Terminate the agent process
4. Verify capability automatically revoked
5. Verify process termination audit event

**Validates**:
- Process monitoring integration
- Automatic revocation on process death
- Audit trail for automatic revocations

### ✅ Telemetry Events (Test: line 285)

**What it tests**:
1. Attach telemetry handlers
2. Grant capability (emits telemetry)
3. Authorize successfully (emits telemetry)
4. Authorize with expired capability (emits denied telemetry)
5. Verify all expected events emitted

**Validates**:
- Telemetry integration works
- Events emitted for all operations
- Monitoring can track security operations

### ✅ Concurrent Load Performance (Test: line 354)

**What it tests**:
1. Spawn 5 concurrent agent tasks
2. Each performs 3 operations (grant, authorize, revoke)
3. Total: 15 concurrent operations
4. Verify at least 50% succeed (rate limiting may block some)
5. Verify audit trail captured all successful operations

**Validates**:
- Concurrent access to PostgreSQL works
- ETS cache handles concurrent reads
- Rate limiting doesn't break persistence
- Audit logger buffers and flushes correctly

### ✅ Error Handling (Tests: lines 449-504)

**What it tests**:
- Database connection failures
- Malformed capability data
- Invalid resource URIs
- Edge cases and validation

**Validates**:
- Graceful degradation
- Clear error messages
- Input validation

---

## PostgreSQL Database Setup

### Automatic (Recommended)

Tests automatically:
1. Create database if it doesn't exist
2. Run migrations
3. Clean tables between tests

No manual setup required!

### Manual (If Automatic Fails)

```bash
# Create test database
MIX_ENV=test mix ecto.create -r Arbor.Security.Repo

# Run migrations
MIX_ENV=test mix ecto.migrate -r Arbor.Security.Repo

# Verify
psql -U arbor_test -d arbor_security_test -c "\dt"
```

---

## Continuous Integration (CI)

### GitHub Actions Example

```yaml
name: Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:14
        env:
          POSTGRES_USER: arbor_test
          POSTGRES_PASSWORD: arbor_test
          POSTGRES_DB: arbor_security_test
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432

    steps:
      - uses: actions/checkout@v3

      - name: Set up Elixir
        uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.15.7'
          otp-version: '26.1'

      - name: Install dependencies
        run: mix deps.get

      - name: Run tests
        env:
          CI: true
          POSTGRES_HOST: localhost
          POSTGRES_USER: arbor_test
          POSTGRES_PASSWORD: arbor_test
          POSTGRES_DB: arbor_security_test
        run: mix test --include integration
```

### GitLab CI Example

```yaml
test:
  image: elixir:1.15.7

  services:
    - postgres:14

  variables:
    CI: "true"
    POSTGRES_HOST: postgres
    POSTGRES_USER: arbor_test
    POSTGRES_PASSWORD: arbor_test
    POSTGRES_DB: arbor_security_test
    MIX_ENV: test

  before_script:
    - mix local.hex --force
    - mix local.rebar --force
    - mix deps.get

  script:
    - mix test --include integration
```

---

## Test Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CI` | `false` | CI mode (excludes chaos/distributed) |
| `TEST_WATCH` | `false` | Watch mode (only fast tests) |
| `ARBOR_INTEGRATION` | `false` | Include integration tests |
| `ARBOR_DISTRIBUTED_TEST` | `false` | Include distributed tests |
| `POSTGRES_HOST` | `localhost` | PostgreSQL hostname |
| `POSTGRES_USER` | `arbor_test` | PostgreSQL username |
| `POSTGRES_PASSWORD` | `arbor_test` | PostgreSQL password |
| `POSTGRES_DB` | `arbor_security_test` | Test database name |

### Test Tags

| Tag | Description | Default |
|-----|-------------|---------|
| `:fast` | Fast unit tests (< 2 min) | ✅ Included |
| `:integration` | Integration tests with real DB | ❌ Excluded |
| `:contract` | Contract boundary tests | ❌ Excluded |
| `:distributed` | Multi-node tests | ❌ Excluded |
| `:chaos` | Chaos engineering tests | ❌ Excluded |

---

## Troubleshooting

### Issue: "Database does not exist"

**Solution**: Tests should auto-create, but if they don't:
```bash
MIX_ENV=test mix ecto.create -r Arbor.Security.Repo
```

### Issue: "Connection refused to localhost:5432"

**Solutions**:
1. Start PostgreSQL: `sudo service postgresql start`
2. Check PostgreSQL is running: `pg_isready`
3. Verify credentials in `config/test.exs`

### Issue: "Table does not exist"

**Solution**: Tests should auto-migrate, but if they don't:
```bash
MIX_ENV=test mix ecto.migrate -r Arbor.Security.Repo
```

### Issue: "Tests timing out"

**Solution**: Increase timeout in test:
```elixir
@moduletag timeout: 30_000  # 30 seconds
```

### Issue: "Too many database connections"

**Solution**: Reduce test concurrency:
```bash
mix test --max-cases 1
```

Or increase pool size in `config/test.exs`:
```elixir
pool_size: 20
```

---

## Test Coverage

### Current Coverage

```bash
# Run with coverage
mix test --cover

# Generate HTML coverage report
mix test --cover --export-coverage default
mix test.coverage
```

**Target**: ≥80% coverage
**Current**: ~80% (on target)

### View Coverage Report

```bash
# After running tests with --cover
open cover/excoveralls.html
```

---

## Performance Benchmarks

### Expected Test Performance

| Test Suite | Duration | Operations |
|------------|----------|------------|
| Fast unit tests | ~30s | Mock-based |
| Integration tests | ~2-3 min | 644 lines, 15+ concurrent ops |
| Full suite | ~5-10 min | All tests |

### Integration Test Performance

From the concurrent load test (line 354):
- **5 agents** × **3 operations** = **15 concurrent operations**
- **Expected success rate**: ≥50% (rate limiting may block some)
- **Audit events**: 2+ per successful operation
- **Duration**: ~5-10 seconds

---

## Adding New Tests

### Template for Persistence Test

```elixir
test "your test description" do
  # 1. Grant capability
  assert {:ok, capability} =
           Kernel.grant_capability(
             principal_id: "agent_test_001",
             resource_uri: "arbor://your/resource",
             constraints: %{max_uses: 5},
             granter_id: "test_admin",
             metadata: %{test: "your_test"}
           )

  # 2. Verify persistence
  assert {:ok, stored_cap} = CapabilityStore.get_capability(capability.id)
  assert stored_cap.id == capability.id

  # 3. Verify cache
  assert {:ok, cached_cap} = CapabilityStore.get_capability_cached(capability.id)
  assert cached_cap.id == capability.id

  # 4. Authorize
  assert {:ok, :authorized} =
           Kernel.authorize(
             capability: capability,
             resource_uri: "arbor://your/resource/specific",
             operation: :your_operation,
             context: %{agent_id: "agent_test_001"}
           )

  # 5. Verify audit events
  :ok = AuditLogger.flush_events()
  assert {:ok, events} = AuditLogger.get_events(filters: [capability_id: capability.id])
  assert length(events) >= 2  # grant + authorize

  # 6. Cleanup
  :ok = Kernel.revoke_capability(
    capability_id: capability.id,
    reason: :test_cleanup,
    revoker_id: "test_admin",
    cascade: false
  )
end
```

### Tag Your Test

```elixir
@tag :integration  # Requires real database
@tag timeout: 10_000  # 10 second timeout
```

---

## Summary

### ✅ What's Automated

- [x] Database creation (automatic)
- [x] Schema migrations (automatic)
- [x] Table cleanup between tests (automatic)
- [x] 644 lines of comprehensive integration tests (ready)
- [x] Persistence verification (PostgreSQL + ETS)
- [x] Audit logging verification (buffered + batch flush)
- [x] Performance testing (concurrent load)
- [x] Error handling (edge cases)
- [x] CI/CD ready (environment detection)

### ✅ How to Run

**Development**:
```bash
# Fast tests (default)
mix test

# With persistence integration
mix test --include integration
```

**CI/CD**:
```bash
CI=true mix test --include integration
```

**Specific tests**:
```bash
mix test apps/arbor_security/test/arbor/security/integration_test.exs
```

### 📊 Test Results

After running, you'll see:
- ✅ All capability lifecycle operations tested
- ✅ Persistence verified (PostgreSQL)
- ✅ Cache verified (ETS)
- ✅ Audit trail verified (batch writes)
- ✅ Performance validated (concurrent operations)
- ✅ Error handling validated (graceful degradation)

---

**Status**: ✅ **FULLY AUTOMATED**

No manual steps required. Just run:
```bash
mix test --include integration
```

And watch the automated test suite validate your entire persistent security layer!

---

**Last Updated**: November 18, 2025
**Maintained By**: Arbor Core Team
**Test Coverage**: ~80% (target achieved)
