# Getting Started with Arbor

This guide will help you get Arbor running and explore its current capabilities.

## Prerequisites

- Elixir 1.15.7+ and OTP 26.1+
- PostgreSQL (for persistence layer)
- Git

## Installation

```bash
# Clone the repository
git clone https://github.com/azmaveth/arbor.git
cd arbor

# Run setup (installs dependencies, builds PLT files)
./scripts/setup.sh

# Start the development server
./scripts/dev.sh
```

## Exploring Arbor with IEx

Since the CLI is still under development, the best way to explore Arbor is through the Elixir interactive shell.

### Connect to Running System

In a new terminal:

```bash
./scripts/console.sh
```

### Basic Operations

#### 1. Create a Session

```elixir
# Create a new session
{:ok, session} = Arbor.Core.Sessions.Manager.create_session(%{
  user_id: "test_user",
  metadata: %{purpose: "testing"}
})

session_id = session.id
```

#### 2. Spawn an Agent

```elixir
# Spawn a code analyzer agent
{:ok, agent_info} = Arbor.Core.Gateway.execute_command(
  "spawn_agent",
  %{
    session_id: session_id,
    agent_type: "code_analyzer",
    config: %{}
  },
  %{trace_id: "test-trace-001"}
)

agent_id = agent_info.result.agent_id
```

#### 3. List Active Agents

```elixir
# List all agents in the session
{:ok, result} = Arbor.Core.Gateway.execute_command(
  "list_agents",
  %{session_id: session_id},
  %{trace_id: "test-trace-002"}
)

# Display agent information
result.result.agents
```

#### 4. Execute Agent Commands

```elixir
# Send a command to the agent
{:ok, result} = Arbor.Core.Gateway.execute_command(
  "execute_agent_command",
  %{
    session_id: session_id,
    agent_id: agent_id,
    command: "analyze",
    args: %{target: "lib/arbor/core/gateway.ex"}
  },
  %{trace_id: "test-trace-003"}
)
```

#### 5. Check Agent Status

```elixir
# Get detailed agent information
{:ok, agent_info} = Arbor.Core.HordeSupervisor.get_agent_info(agent_id)
```

## Understanding the Architecture

### Core Components

1. **Gateway** - Central entry point for all operations
   - Manages sessions and command routing
   - Provides unified API

2. **Sessions** - Coordination contexts for agents
   - Manages agent lifecycle
   - Tracks resources and capabilities

3. **Agents** - Autonomous processes with specific capabilities
   - Run in supervised processes
   - Can checkpoint and restore state

4. **Security** - Capability-based access control
   - Fine-grained permissions
   - Audit logging

## Running Tests

```bash
# Run fast test suite
./scripts/test.sh --fast

# Run full test suite
./scripts/test.sh

# Run specific test file
mix test test/arbor/core/gateway_test.exs
```

## Manual Testing Scripts

Explore the manual test scripts for examples:

```bash
# List available manual tests
ls scripts/manual_tests/

# Run gateway manual test
elixir scripts/manual_tests/gateway_manual_test.exs

# Run module loading test
elixir scripts/manual_tests/module_loading_test.exs
```

## Monitoring the System

### Check Cluster Status

```elixir
# In IEx console
Arbor.Core.ClusterManager.get_cluster_status()
```

### View Registered Agents

```elixir
# Get all registered agents
Arbor.Core.HordeRegistry.list_agents()
```

### Monitor Telemetry Events

```elixir
# Attach to telemetry events
:telemetry.attach(
  "print-agent-events",
  [:arbor, :agent, :started],
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata})
  end,
  nil
)
```

## Current Limitations

As Arbor is in alpha stage, several features are not yet implemented:

1. **CLI** - Command-line interface is incomplete
2. **Web UI** - No web interface yet
3. **AI Integration** - LLM integrations not implemented
4. **Authentication** - No user authentication system
5. **Persistence** - Limited persistence capabilities

See [PROJECT_STATUS.md](PROJECT_STATUS.md) for detailed implementation status.

## Next Steps

1. **Explore the Code** - Browse the `/apps` directory to understand the architecture
2. **Run Tests** - Use the test suite to see examples of usage
3. **Read the Docs** - Check `/docs` for architecture and design documentation
4. **Try Manual Tests** - Run scripts in `/scripts/manual_tests` for hands-on exploration

## Getting Help

- **Documentation**: See the `/docs` directory
- **Issues**: [GitHub Issues](https://github.com/azmaveth/arbor/issues)
- **Discussions**: [GitHub Discussions](https://github.com/azmaveth/arbor/discussions)

## Contributing

We welcome contributions! See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines.

---

*Remember: Arbor is alpha software. APIs and features will change as development progresses.*