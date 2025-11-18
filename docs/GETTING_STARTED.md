# Getting Started with Arbor

This guide will help you get Arbor running and explore its capabilities using both the CLI and programmatic API.

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

## Using the Arbor CLI

The Arbor CLI is complete and provides a full-featured interface for managing agents. This is the recommended way to interact with Arbor.

### Basic CLI Commands

```bash
# Spawn a new agent
arbor agent spawn code_analyzer --name my-analyzer --working-dir /tmp

# List all agents
arbor agent list

# List agents with filtering (JSON format example)
arbor agent list --filter '{"type":"code_analyzer"}' --format json

# Get detailed agent status
arbor agent status <agent-id>

# Execute a command on an agent
arbor agent exec <agent-id> analyze_file lib/arbor/core/gateway.ex

# Execute a directory analysis
arbor agent exec <agent-id> analyze_directory lib/arbor/core

# List files in agent's working directory
arbor agent exec <agent-id> list_files .
```

### CLI Features

The CLI provides:
- ✅ **Automatic session management** - No manual session creation needed
- ✅ **Rich terminal output** - Colored output with tables and formatting
- ✅ **Multiple output formats** - table (default), JSON, YAML
- ✅ **Filtering and searching** - Filter agents by type, status, or other criteria
- ✅ **Error handling** - Clear error messages with suggestions

### Example Workflow

```bash
# 1. Start the development server (in one terminal)
./scripts/dev.sh

# 2. In another terminal, spawn an agent
$ arbor agent spawn code_analyzer --name my-analyzer

# Output:
# Agent spawned: code_analyzer_abc123 (type: code_analyzer)

# 3. List agents to verify
$ arbor agent list

# Output shows table:
# Agent ID              | Type          | Status  | Uptime
# -----------------------------------------------------------
# code_analyzer_abc123  | code_analyzer | active  | 2m

# 4. Execute analysis on a file
$ arbor agent exec code_analyzer_abc123 analyze_file lib/arbor/core/gateway.ex

# Output shows analysis results

# 5. Check agent status
$ arbor agent status code_analyzer_abc123

# Shows detailed information including metadata and last activity
```

## Advanced: Using the Programmatic API

For advanced use cases or when building integrations, you can use the direct Elixir API from IEx.

### Connect to Running System

In a new terminal:

```bash
./scripts/console.sh
```

**Note**: If the console connection fails with "Could not connect to arbor@localhost", you can use the IEx session directly in the terminal where you started `./scripts/dev.sh`.

### Basic API Operations

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
{:ok, execution_id} = Arbor.Core.Gateway.execute_command(
  %{
    type: :spawn_agent,
    params: %{
      type: :code_analyzer,
      id: "my_analyzer",
      working_dir: "/tmp"
    }
  },
  %{session_id: session_id},
  %{}
)

# Note: Gateway commands are asynchronous and return execution IDs
IO.puts("Agent spawn started: #{execution_id}")
```

#### 3. Query Agents

```elixir
# Query all agents in the system
{:ok, execution_id} = Arbor.Core.Gateway.execute_command(
  %{
    type: :query_agents,
    params: %{}
  },
  %{session_id: session_id},
  %{}
)

IO.puts("Agent query started: #{execution_id}")

# Alternative: Use lower-level API for synchronous results
case Arbor.Core.HordeSupervisor.list_agents() do
  {:ok, agents} ->
    Enum.each(agents, fn agent ->
      IO.puts("Agent: #{agent.agent_id} - Status: #{agent.status}")
    end)
  {:error, reason} ->
    IO.puts("Error listing agents: #{inspect(reason)}")
end
```

#### 4. Execute Agent Commands

```elixir
# First, get the agent ID (from spawning or by querying)
agent_id = "my_analyzer"

# Send a command to analyze a file
{:ok, execution_id} = Arbor.Core.Gateway.execute_command(
  %{
    type: :execute_agent_command,
    params: %{
      agent_id: agent_id,
      command: :analyze_file,
      args: ["/path/to/file.ex"]
    }
  },
  %{session_id: session_id},
  %{}
)

IO.puts("Agent command started: #{execution_id}")
```

#### 5. Working with Async Commands

All Gateway commands are asynchronous and return execution IDs for tracking:

```elixir
# Example: Spawn an agent and track its execution
command = %{
  type: :spawn_agent,
  params: %{
    type: :code_analyzer,
    id: "async_example_agent",
    working_dir: "/tmp"
  }
}

context = %{session_id: session_id}
options = %{}

# Commands return execution IDs
{:ok, execution_id} = Arbor.Core.Gateway.execute_command(command, context, options)

IO.puts("Command execution started with ID: #{execution_id}")

# Note: Result retrieval mechanisms are under development
# For now, use telemetry events or check agent status
```

#### 6. Check Agent Status

```elixir
# Get detailed agent information
agent_id = "my_analyzer"

case Arbor.Core.HordeSupervisor.get_agent_info(agent_id) do
  {:ok, agent_info} ->
    IO.inspect(agent_info, label: "Agent Info")
  {:error, :not_found} ->
    IO.puts("Agent #{agent_id} not found")
  {:error, reason} ->
    IO.puts("Error getting agent info: #{inspect(reason)}")
end
```

## Understanding the Architecture

### Core Components

1. **Gateway** - Central entry point for all operations
   - Manages sessions and command routing
   - Provides unified API
   - Async execution model with tracking

2. **Sessions** - Coordination contexts for agents
   - Manages agent lifecycle
   - Tracks resources and capabilities
   - Distributed across cluster

3. **Agents** - Autonomous processes with specific capabilities
   - Run in supervised processes
   - Can checkpoint and restore state
   - Distributed via Horde supervision

4. **Security** - Capability-based access control
   - Fine-grained permissions
   - Audit logging
   - ⚠️ Currently using in-memory mocks (production persistence in progress)

### Available Agent Types

#### CodeAnalyzer (Production-Ready)
Analyzes Elixir code files and directories.

**Commands**:
- `analyze_file <path>` - Analyze a single file (LOC, language, complexity)
- `analyze_directory <path>` - Analyze all files in a directory
- `list_files <path>` - List files (with security restrictions)

**Security Features**:
- Path traversal protection
- File size limits (10MB)
- Working directory isolation

## Running Tests

```bash
# Run intelligent test dispatcher (context-aware)
mix test

# Run fast test suite only
mix test --only fast

# Run specific test file
mix test test/arbor/core/gateway_test.exs

# Run full test suite with coverage
./scripts/test.sh --coverage
```

## Manual Testing Scripts

Explore the manual test scripts for examples:

```bash
# List available manual tests
ls scripts/manual_tests/

# Run gateway integration test
elixir scripts/manual_tests/gateway_integration_test.exs

# Run CLI integration test
elixir scripts/manual_tests/cli_integration_test.exs

# Run module loading test
elixir scripts/manual_tests/module_loading_test.exs
```

## Monitoring the System

### Using IEx Console

```elixir
# Check cluster status
Arbor.Core.ClusterManager.cluster_status()

# Get registry status
Arbor.Core.HordeRegistry.get_status()

# Monitor telemetry events
:telemetry.attach(
  "print-agent-events",
  [:arbor, :agent, :started],
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata})
  end,
  nil
)
```

## Troubleshooting

### Common Issues

#### Database Connection Errors

If you see database-related errors:

```bash
# Create databases
mix ecto.create
createdb arbor_security_dev  # If needed
```

#### Missing Dependencies

```bash
mix deps.get
mix compile
```

#### Application Startup

✅ **Resolved**: Application startup issues have been fixed as of June 2025. The development server should start reliably with `./scripts/dev.sh`.

If you encounter issues:
1. Check that PostgreSQL is running
2. Verify Elixir/OTP versions (1.15.7+/26.1+)
3. Run `./scripts/setup.sh` again

### Known Issues

1. **Agent Registration Race Conditions**
   - Agents may take multiple retries to register successfully during high load
   - Workaround: The system automatically retries
   - Fix scheduled for Priority 1.3

2. **Security Persistence** ⚠️ **Production Blocker**
   - CapabilityStore and AuditLogger use in-memory storage
   - All security data lost on restart
   - Not suitable for production use
   - Fix in progress (Priority 1.2)

3. **Scalability Limits**
   - Registry scans won't scale beyond ~1K agents
   - Fix scheduled for Priority 1.4

See [PROJECT_STATUS.md](PROJECT_STATUS.md) for detailed status and [PLAN_UPDATED.md](../PLAN_UPDATED.md) for roadmap.

## Current Development Status

As of November 2025, Arbor is in **alpha stage (v0.2.0-dev)**:

**✅ Complete**:
- CLI with full agent management commands
- Core infrastructure and distributed supervision
- Agent spawning, querying, and execution
- CodeAnalyzer production agent
- Gateway pattern and session management

**🚧 In Progress**:
- Persistent security layer (Priority 1.2 - Critical)
- Agent registration stability improvements
- Scalability enhancements

**❌ Not Yet Implemented**:
- Interactive CLI mode
- Configuration file support
- Web UI
- AI integration (LLM adapters)
- Additional agent types
- Authentication/authorization

## Next Steps

### For Users

1. **Try the CLI** - Use `arbor agent spawn` to create your first agent
2. **Run Tests** - Explore the test suite for usage examples
3. **Read Architecture Docs** - Check `/docs/arbor` for detailed design docs
4. **Experiment with Manual Tests** - Run scripts in `/scripts/manual_tests`

### For Developers

1. **Read CLAUDE.md** - Development guidelines and conventions
2. **Review PLAN_UPDATED.md** - Current roadmap and priorities
3. **Check PROJECT_STATUS.md** - Detailed implementation status
4. **Join Development** - See Priority 1.2 for critical work items

## Getting Help

- **Documentation**: See the `/docs` directory
- **Planning**: [PLAN_UPDATED.md](../PLAN_UPDATED.md) - Development roadmap
- **Status**: [PROJECT_STATUS.md](PROJECT_STATUS.md) - Current implementation state
- **Issues**: [GitHub Issues](https://github.com/azmaveth/arbor/issues)
- **Discussions**: [GitHub Discussions](https://github.com/azmaveth/arbor/discussions)

## Contributing

We welcome contributions! See [CONTRIBUTING.md](../CONTRIBUTING.md) for guidelines.

Current priorities:
- **Priority 1.2**: Implement persistent security layer (CapabilityStore, AuditLogger)
- **Priority 1.3**: Resolve agent registration race conditions
- **Priority 1.4**: Improve registry scalability

---

*Arbor is alpha software under active development. The CLI is production-ready, but core security persistence is needed before production deployment. See [PLAN_UPDATED.md](../PLAN_UPDATED.md) for timeline.*
