# Arbor Test Infrastructure

This document describes Arbor's intelligent test infrastructure, designed to be **simple to use but comprehensive in coverage**. The system automatically chooses the right test suite based on your environment and needs.

## Quick Start

For most development work, just run:

```bash
mix test
```

The system automatically detects your environment and runs the appropriate test suite:

- **Local Development**: Runs fast unit tests (< 2 minutes)
- **CI Environment**: Runs comprehensive suite excluding expensive tests (< 10 minutes)  
- **Distributed Mode**: Runs full test suite including multi-node tests (< 30 minutes)

## Test Suite Overview

Arbor organizes tests into five tiers by execution time and scope:

| Tier | Tag | Duration | Description | Scope |
|------|-----|----------|-------------|--------|
| **Fast** | `:fast` | < 2 min | Unit tests with mocks | Single functions/modules |
| **Contract** | `:contract` | ~3 min | Interface boundary tests | API contracts & behaviors |
| **Integration** | `:integration` | ~8 min | Single-node end-to-end | Full workflows, real processes |
| **Distributed** | `:distributed` | ~15 min | Multi-node cluster tests | Distributed coordination |
| **Chaos** | `:chaos` | ~30 min | Fault injection tests | Failure scenarios |

## Smart Test Execution

### Automatic Environment Detection

The test system automatically chooses the appropriate suite:

```bash
# Local development (default)
mix test
# → Runs: Fast suite (< 2 min)

# CI environment  
CI=true mix test
# → Runs: Fast + Contract + Integration (< 10 min)

# Distributed testing
DISTRIBUTED=true mix test  
# → Runs: All test tiers including chaos (< 30 min)
```

### Manual Override

You can override the automatic selection by specifying test filters:

```bash
# Run specific test tiers
mix test --only fast                    # Fast tests only
mix test --only contract               # Contract tests only
mix test --only integration            # Integration tests only

# Run combinations
mix test --exclude distributed,chaos   # Everything except expensive tests
mix test --only fast,contract          # Fast and contract tests

# Run specific files/directories
mix test test/arbor/core/gateway_test.exs
mix test apps/arbor_core/test/
```

## Test Commands Reference

### Primary Commands (Recommended)

```bash
# Smart test execution (recommended for daily use)
mix test                    # Environment-aware intelligent routing

# Help and documentation
mix test --help            # Show detailed test options
```

### Development Workflow Commands

```bash
# Pre-commit validation (fast subset)
mix test.pre_commit        # Format check + Credo + Fast tests

# Development testing
mix test.fast              # Fast unit tests only (< 2 min)
mix test.watch             # Watch mode for fast tests
```

### Comprehensive Testing Commands

```bash
# Full test suites
mix test.ci                # CI-appropriate tests (fast + contract + integration)
mix test.all               # All tests including expensive ones (use with caution)

# Specific test tiers
mix test.contract          # Interface boundary tests
mix test.integration       # Single-node end-to-end tests
mix test.distributed       # Multi-node cluster tests (requires setup)
mix test.chaos             # Fault injection tests (very slow)
```

### Coverage and Quality Commands

```bash
# Coverage analysis
mix test.cover             # Coverage report (excludes slow tests)
mix test.coverage.full     # Full coverage including distributed tests

# Combined quality checks
mix quality                # Format + Credo + Dialyzer (no tests)
```

## Writing Tests

### Test Organization

Organize your tests using ExUnit tags to ensure they run in the correct tier:

```elixir
defmodule MyModuleTest do
  use ExUnit.Case, async: true
  
  # Fast unit tests (default tier)
  @moduletag :fast
  
  describe "unit functionality" do
    @tag :fast
    test "does unit computation" do
      assert MyModule.compute(1, 2) == 3
    end
  end
  
  describe "contract validation" do
    @tag :contract
    test "validates API contract" do
      assert {:ok, _} = MyModule.validate_input(%{required: "data"})
    end
  end
  
  describe "integration behavior" do
    @tag :integration
    test "performs end-to-end workflow" do
      # Test with real processes, databases, etc.
    end
  end
  
  describe "distributed coordination" do
    @tag :distributed
    test "coordinates across multiple nodes" do
      # Requires distributed test environment
    end
  end
  
  describe "fault tolerance" do
    @tag :chaos
    test "handles network partitions" do
      # Fault injection and recovery testing
    end
  end
end
```

### Test Tagging Guidelines

**`:fast` - Unit Tests (< 2 minutes total)**
- Pure function testing with mocks
- No external dependencies (databases, networks, file I/O)
- Use Mox for all external boundaries
- Should be safe to run in parallel

**`:contract` - Interface Boundary Tests (~3 minutes total)**
- Test API contracts and behavior implementations
- Test module interfaces and protocol implementations
- Validate data structures and type contracts
- May use lightweight in-memory dependencies

**`:integration` - End-to-End Tests (~8 minutes total)**
- Single-node workflows with real processes
- Database integration (with test database)
- File system operations
- May start supervision trees and applications

**`:distributed` - Multi-Node Tests (~15 minutes total)**
- Cluster coordination and synchronization
- Inter-node communication testing
- Requires distributed test environment setup
- Tests Horde-based distributed processes

**`:chaos` - Fault Injection Tests (~30 minutes total)**
- Network partition simulation
- Process crash and recovery testing
- Resource exhaustion scenarios
- Extremely slow, run only when needed

### Test Support Modules

Use the provided test support modules:

```elixir
# Fast unit tests
import Mox                           # Contract-based mocking
use Arbor.Test.Support.MoxSetup     # Automated mock setup

# Integration tests  
use Arbor.Core.Test.IntegrationCase # Integration test helpers

# Distributed tests
use Arbor.Test.Support.MultiNodeTestHelper     # Multi-node coordination
use Arbor.Test.Support.ClusterTestHelper       # Cluster testing utilities
```

## Environment Setup

### Local Development

No special setup required. The test system automatically:

- Uses Mox-based mocks for external dependencies
- Runs only fast tests by default
- Provides immediate feedback for development iteration

### CI Environment

Set the `CI` environment variable:

```bash
export CI=true
mix test  # Automatically runs CI-appropriate test suite
```

The CI suite includes fast, contract, and integration tests but excludes expensive distributed and chaos tests.

### Distributed Testing

For distributed testing (e.g., testing Horde cluster behavior):

```bash
export DISTRIBUTED=true
mix test  # Runs full test suite including multi-node tests
```

**Requirements for distributed testing:**
- Docker or multiple Erlang nodes
- Network connectivity between test nodes
- Extended timeout configurations
- Sufficient system resources

## Test Performance Guidelines

### Expected Execution Times

| Command | Local Dev | CI Environment | Full Suite |
|---------|-----------|----------------|------------|
| `mix test` | < 2 min | < 10 min | < 30 min |
| `mix test.fast` | < 2 min | < 2 min | < 2 min |
| `mix test.ci` | N/A | < 10 min | < 10 min |
| `mix test.all` | ~30 min | ~30 min | ~30 min |

### Performance Optimization

**For faster development iteration:**
```bash
mix test.fast              # Unit tests only
mix test.watch             # Continuous testing
mix test --failed          # Re-run only failed tests
```

**For comprehensive validation:**
```bash
mix test.pre_commit        # Quick pre-commit checks
mix test.ci                # Full CI validation
```

## Troubleshooting

### Common Issues

**"Running Fast suite but tests seem slow"**
- Check that your tests are properly tagged with `:fast`
- Ensure no integration dependencies in unit tests
- Verify Mox mocks are being used instead of real services

**"Distributed tests failing locally"**
- Ensure `DISTRIBUTED=true` environment variable is set
- Check that required distributed infrastructure is running
- Verify network connectivity between test nodes

**"CI tests timing out"**
- CI environment automatically excludes expensive tests
- Check for untagged tests that may be running in wrong tier
- Verify database and external service availability

### Getting Help

```bash
mix test --help            # Detailed ExUnit options
mix help test             # Mix task documentation
```

**Test Infrastructure Questions:**
- Check this TEST.md documentation
- Review test examples in `test/` directories
- See CLAUDE.md for development patterns

## Advanced Usage

### Custom Test Environments

You can create custom test environments by combining filters:

```bash
# Custom fast + contract suite
mix test --exclude integration,distributed,chaos

# Security-focused testing
mix test --only security

# Performance testing  
mix test --only performance
```

### Coverage Analysis

Generate coverage reports to identify untested code:

```bash
# Standard coverage (excludes slow tests)
mix test.cover

# Comprehensive coverage (includes all tests)
mix test.coverage.full

# Coverage with specific filters
mix test --cover --only fast,contract
```

### Test Partitioning

For large test suites, use ExUnit's built-in partitioning:

```bash
# Split tests across 4 parallel processes
MIX_TEST_PARTITION=1 mix test --partitions 4
MIX_TEST_PARTITION=2 mix test --partitions 4
MIX_TEST_PARTITION=3 mix test --partitions 4  
MIX_TEST_PARTITION=4 mix test --partitions 4
```

## Migration Guide

### From Previous Test System

The new system maintains backward compatibility with all existing test commands while adding intelligent routing:

**Old Approach:**
```bash
mix test.fast              # Still works
mix test.integration       # Still works  
mix test --only integration # Still works
```

**New Recommended Approach:**
```bash
mix test                   # Intelligent environment-aware testing
```

### Updating Existing Tests

1. **Add appropriate tags** to your existing tests
2. **Replace hand-written mocks** with Mox-based implementations  
3. **Move integration setup** to appropriate test support modules
4. **Update CI scripts** to use `CI=true mix test`

---

*This documentation covers the core test infrastructure. For implementation details and development patterns, see [CLAUDE.md](./CLAUDE.md).*