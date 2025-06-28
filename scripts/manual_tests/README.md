# Manual Test Scripts

This directory contains manual test scripts that are useful for exploratory testing, debugging, and understanding system behavior. These scripts are not part of the automated test suite but serve as valuable tools for development and troubleshooting.

## Scripts Overview

### CLI and Integration Tests

- **`cli_integration_test.exs`** - Tests HTTP API integration between CLI and Core
  - Tests server availability, session creation, and command execution
  - Useful for verifying the HTTP gateway is working correctly
  - Run with: `elixir scripts/manual_tests/cli_integration_test.exs`

- **`gateway_integration_test.exs`** - Tests the "steel thread" from Gateway commands to Agent execution
  - End-to-end test of session creation, agent spawning, listing, and command execution
  - Validates the complete flow through the system
  - Run with: `elixir scripts/manual_tests/gateway_integration_test.exs`

### System Component Tests

- **`gateway_manual_test.exs`** - Comprehensive manual testing of Gateway functionality
  - Tests Gateway startup, session lifecycle, capability discovery, event subscription
  - Includes async execution and statistics verification
  - Run with: `elixir scripts/manual_tests/gateway_manual_test.exs`

- **`module_loading_test.exs`** - Verifies basic module loading and type generation
  - Ensures all core modules can be loaded
  - Tests type generation (agent_id, session_id, capability_id)
  - Validates URI parsing and validation
  - Run with: `elixir scripts/manual_tests/module_loading_test.exs`

### Debugging and Exploration

- **`horde_registry_exploration.exs`** - Explores Horde.Registry behavior and patterns
  - Tests different select patterns for registry queries
  - Useful for understanding how to query the distributed registry
  - Run with: `elixir scripts/manual_tests/horde_registry_exploration.exs`

- **`debug_agent_registration.exs`** - Debug script for testing agent registration flow
  - Creates a minimal test agent and attempts registration
  - Useful for debugging registration issues
  - Run with: `elixir scripts/manual_tests/debug_agent_registration.exs`

## Usage

These scripts are designed to be run manually during development:

```bash
# Start the dev server first (in another terminal)
./scripts/dev.sh

# Then run a manual test
elixir scripts/manual_tests/<script_name>.exs
```

## When to Use These Scripts

- **During Development**: To quickly test specific functionality without running the full test suite
- **Debugging Issues**: When automated tests fail and you need more visibility into system behavior
- **Learning the System**: To understand how different components interact
- **Performance Testing**: Some scripts can be modified for ad-hoc performance testing
- **Integration Verification**: To ensure external integrations (HTTP API, distributed features) work correctly

## Notes

- These scripts may require the system to be running (`./scripts/dev.sh`)
- Some scripts may need to be updated as the system evolves
- They are not run as part of CI/CD - they're purely for manual testing
- Feel free to modify these scripts for your specific testing needs