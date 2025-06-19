# Arbor Development Guide

This comprehensive guide covers everything you need to know for developing with Arbor, from initial setup through advanced development workflows.

## 🚀 Quick Start

### System Requirements

**Minimum Requirements:**
- **Elixir**: 1.15.7 or higher
- **Erlang/OTP**: 26.1 or higher
- **Git**: 2.30+ for optimal experience
- **Memory**: 4GB RAM minimum, 8GB recommended
- **Storage**: 2GB free space

**Recommended Tools:**
- **asdf**: Version manager for Elixir/Erlang
- **Docker**: For containerized development and observability stack
- **VS Code** or **IntelliJ** with Elixir extensions

### Installation Methods

#### Method 1: Using asdf (Recommended)

```bash
# Install asdf if not already installed
git clone https://github.com/asdf-vm/asdf.git ~/.asdf
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
source ~/.bashrc

# Add Elixir and Erlang plugins
asdf plugin add erlang
asdf plugin add elixir

# Install versions from .tool-versions file
asdf install

# Verify installation
elixir --version
erl -version
```

#### Method 2: Package Managers

**macOS (Homebrew):**
```bash
brew install elixir
```

**Ubuntu/Debian:**
```bash
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt-get update
sudo apt-get install esl-erlang elixir
```

**Arch Linux:**
```bash
sudo pacman -S elixir
```

### Project Setup

1. **Clone the repository:**
   ```bash
   git clone https://github.com/azmaveth/arbor.git
   cd arbor
   ```

2. **Run automated setup:**
   ```bash
   ./scripts/setup.sh
   ```

   This script will:
   - Verify prerequisites
   - Install Hex and Rebar3
   - Install project dependencies
   - Build Dialyzer PLT files
   - Run initial tests
   - Create necessary directories

3. **Verify installation:**
   ```bash
   ./scripts/test.sh --fast
   ```

## 🏗️ Project Architecture

### Umbrella Structure

Arbor uses an **Elixir umbrella project** with four main applications:

```text
apps/
├── arbor_contracts/      # 🔗 Foundation layer (zero dependencies)
│   ├── schemas/          # Data structure definitions
│   ├── types/            # Type specifications
│   └── protocols/        # Behavior contracts
├── arbor_security/       # 🛡️ Security & capability management
│   ├── kernel/           # Capability granting engine
│   ├── audit/            # Security event logging
│   └── auth/             # Authentication systems
├── arbor_persistence/    # 💾 State management & storage
│   ├── event_store/      # Event sourcing implementation
│   ├── projections/      # CQRS read models
│   └── adapters/         # Storage backend adapters
└── arbor_core/           # 🧠 Core business logic
    ├── agents/           # Agent management & orchestration
    ├── sessions/         # Multi-agent coordination
    ├── tasks/            # Task distribution & execution
    └── supervisors/      # OTP supervision trees
```

### Dependency Flow

**Strict dependency hierarchy** ensures modularity and testability:

```text
arbor_contracts (foundational, no deps)
    ↑
arbor_security ← arbor_persistence
    ↑               ↑
arbor_core ←--------┘
```

**Rules:**
- `arbor_contracts` has **zero external dependencies**
- Dependencies flow **upward only** (no circular dependencies)
- Each app has a **single, clear responsibility**
- Inter-app communication through **well-defined contracts**

## 🛠️ Development Workflow

### Daily Development Commands

```bash
# Start development server with distributed capabilities
./scripts/dev.sh

# In another terminal - run tests continuously
./scripts/test.sh --fast

# Generate comprehensive coverage report
./scripts/test.sh --coverage

# Connect to running development node for debugging
./scripts/console.sh

# Performance benchmarking
./scripts/benchmark.sh
```

### Development Server Features

The `./scripts/dev.sh` script starts:
- **IEx session** with full project loaded
- **Distributed node** (`arbor@localhost`)
- **Hot code reloading** enabled
- **Unicode support** for proper output
- **Development cookie** for remote connections

### Testing Strategy

#### Test Categories

**Unit Tests:**
```bash
# Run all unit tests
mix test

# Run specific test file
mix test test/arbor/core/agent_supervisor_test.exs

# Run tests with pattern matching
mix test --only property
mix test --only integration
```

**Integration Tests:**
```bash
# Full integration test suite
mix test --only integration

# Database integration tests
mix test test/arbor/persistence/integration/
```

**Property-Based Tests:**
```bash
# Run property-based tests (using StreamData)
mix test --only property

# Generate test data samples
mix test --seed 42 --only property
```

**Performance Tests:**
```bash
# Benchmarking with Benchee
./scripts/benchmark.sh --suite all

# Specific benchmark suites
./scripts/benchmark.sh --suite messaging
./scripts/benchmark.sh --suite persistence
```

#### Test Configuration

**Coverage Configuration** (`coveralls.json`):
```json
{
  "coverage_options": {
    "minimum_coverage": 80,
    "treat_no_relevant_lines_as_covered": true
  },
  "skip_files": [
    "test/",
    "deps/"
  ]
}
```

**Test Aliases** (`mix.exs`):
```elixir
defp aliases do
  [
    "test.all": ["test", "test --only integration"],
    "test.ci": ["test --cover", "coveralls"],
    "test.watch": ["test.watch"]
  ]
end
```

### Code Quality Tools

#### Static Analysis with Credo

```bash
# Run Credo checks
mix credo

# Strict mode (fails on any issues)
mix credo --strict

# Generate suggestions
mix credo suggest

# Check specific files
mix credo lib/arbor/core/agent_supervisor.ex
```

**Credo Configuration** (`.credo.exs`):
```elixir
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "test/", "web/", "apps/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      strict: true,
      checks: [
        # Enabled checks
        {Credo.Check.Consistency.TabsOrSpaces},
        {Credo.Check.Design.TagTODO, exit_status: 0},
        
        # Disabled checks
        {Credo.Check.Readability.LargeNumbers, false}
      ]
    }
  ]
}
```

#### Type Checking with Dialyzer

```bash
# Build PLT (first time, slow)
mix dialyzer --plt

# Run type checking
mix dialyzer

# Check specific files
mix dialyzer lib/arbor/core/agent_supervisor.ex

# Explain warnings
mix dialyzer --explain
```

**Dialyzer Configuration** (`mix.exs`):
```elixir
defp dialyzer do
  [
    plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
    plt_add_apps: [:mix, :ex_unit],
    flags: [:error_handling, :race_conditions, :underspecs]
  ]
end
```

### Hot Code Reloading

Arbor supports **hot code reloading** during development:

```elixir
# In IEx session
iex> recompile()
Compiling 1 file (.ex)
:ok

# Reload specific modules
iex> r Arbor.Core.AgentSupervisor
{:reloaded, [Arbor.Core.AgentSupervisor]}

# Check running processes
iex> Process.list() |> length()
42
```

## 🐛 Debugging Techniques

### IEx Debugging

```elixir
# Start with debugging enabled
iex --dbg pry -S mix

# Set breakpoints in code
require IEx; IEx.pry()

# Inspect process state
iex> Process.info(pid)
iex> :sys.get_state(pid)

# Trace function calls
iex> :dbg.tracer()
iex> :dbg.p(pid, [:call])
iex> :dbg.tpl(Arbor.Core.Agent, :spawn, [])
```

### Observability Tools

**Observer (GUI):**
```elixir
# Start Observer GUI
iex> :observer.start()
```

**Observer CLI (Terminal):**
```elixir
# Start terminal-based observer
iex> :observer_cli.start()
```

**Process Inspection:**
```elixir
# Find processes by name
iex> Process.whereis(Arbor.Core.AgentSupervisor)

# Inspect supervision tree
iex> Supervisor.which_children(Arbor.Core.Supervisor)

# Check process mailbox
iex> Process.info(pid, :message_queue_len)
```

### Distributed Debugging

```bash
# Connect to remote node
./scripts/console.sh --node arbor@remote.host

# Inspect cluster status
iex> Node.list()
iex> :net_adm.ping(:"arbor@other.node")

# Distributed process inspection
iex> :global.registered_names()
iex> :rpc.call(node, Module, function, args)
```

## 🔧 Configuration Management

### Environment Configuration

**Development** (`config/dev.exs`):
```elixir
import Config

config :arbor_core,
  distributed: true,
  node_name: "arbor@localhost",
  cookie: :arbor_dev,
  telemetry_enabled: true

config :logger,
  level: :debug,
  format: "$time $metadata[$level] $message\n"
```

**Test** (`config/test.exs`):
```elixir
import Config

config :arbor_core,
  distributed: false,
  async_testing: true

config :logger, level: :warn

# Fast test database
config :arbor_persistence,
  adapter: Arbor.Persistence.Adapters.Memory
```

**Production** (`config/prod.exs`):
```elixir
import Config

config :arbor_core,
  distributed: true,
  telemetry_enabled: true

config :logger,
  level: :info,
  backends: [LoggerJSON]
```

### Runtime Configuration

**Environment Variables:**
```bash
# Development
export MIX_ENV=dev
export ARBOR_NODE_NAME=arbor@dev.local
export ARBOR_COOKIE=secure_dev_cookie

# Observability
export PROMETHEUS_ENDPOINT=http://localhost:9090
export JAEGER_ENDPOINT=http://localhost:14250

# Security
export ARBOR_SECRET_KEY_BASE=$(mix phx.gen.secret)
export ARBOR_CAPABILITY_KEY=$(mix phx.gen.secret)
```

## 📊 Performance Optimization

### Benchmarking

**Using Benchee:**
```elixir
defmodule Arbor.Core.AgentBench do
  use Benchee
  
  def run do
    Benchee.run(%{
      "spawn_agent" => fn -> Arbor.Core.spawn_agent(:worker, %{}) end,
      "spawn_agent_supervised" => fn -> 
        Arbor.Core.spawn_agent_supervised(:worker, %{}) 
      end
    },
    time: 10,
    memory_time: 2,
    formatters: [
      Benchee.Formatters.HTML,
      Benchee.Formatters.Console
    ])
  end
end
```

**Running Benchmarks:**
```bash
# All benchmarks
./scripts/benchmark.sh

# Specific suites
./scripts/benchmark.sh --suite messaging
./scripts/benchmark.sh --suite persistence

# With output formats
./scripts/benchmark.sh --format html --save
```

### Profiling

**Using :fprof:**
```elixir
# Profile function execution
:fprof.apply(Arbor.Core, :heavy_function, [args])
:fprof.profile()
:fprof.analyse()
```

**Using :eprof:**
```elixir
# Profile process execution
:eprof.start_profiling([pid])
# ... run code ...
:eprof.stop_profiling()
:eprof.analyze()
```

### Memory Analysis

```elixir
# Check memory usage
iex> :erlang.memory()

# Process memory inspection
iex> Process.info(pid, :memory)

# Garbage collection stats
iex> :erlang.garbage_collect(pid)
```

## 🐳 Docker Development

### Using Docker Compose

```bash
# Start full development environment
docker-compose up -d

# View logs
docker-compose logs -f arbor

# Execute commands in container
docker-compose exec arbor iex

# Scale services
docker-compose up -d --scale arbor=3
```

### Container Development Workflow

```bash
# Build development image
docker build --target debug -t arbor:dev .

# Run with hot reloading
docker run -it --rm \
  -v $(pwd):/app \
  -p 4000:4000 \
  arbor:dev \
  ./scripts/dev.sh
```

## 🧪 Testing in Different Environments

### Local Testing

```bash
# Unit tests only
mix test --exclude integration

# Integration tests only  
mix test --only integration

# Property-based tests
mix test --only property

# Slow tests (full suite)
mix test --include slow
```

### CI/CD Testing

```bash
# Run CI test suite locally
./scripts/test.sh --ci

# Generate CI coverage report
mix coveralls.html --umbrella
```

### Load Testing

```bash
# Performance test suite
./scripts/benchmark.sh --suite load

# Stress testing
MIX_ENV=test mix run scripts/stress_test.exs
```

## 🔍 Troubleshooting

### Common Issues

**Dialyzer PLT Issues:**
```bash
# Clear and rebuild PLT
rm -rf _build/*/dialyxir_*
./scripts/setup.sh
```

**Dependency Conflicts:**
```bash
# Clean and reinstall dependencies
mix deps.clean --all
mix deps.get
mix deps.compile
```

**Port Conflicts:**
```bash
# Find processes using ports
lsof -i :4000
lsof -i :9001

# Kill processes if needed
pkill -f "beam.smp"
```

**Memory Issues:**
```bash
# Increase EVM memory
export ERL_MAX_PORTS=32768
export ERL_MAX_ETS_TABLES=32768
```

### Development Server Issues

**Node Connection Problems:**
```bash
# Check node is running
./scripts/console.sh --node arbor@localhost

# Verify cookie consistency
cat ~/.erlang.cookie

# Reset distributed environment
pkill -f "epmd"
epmd -daemon
```

**Hot Reloading Not Working:**
```elixir
# Force recompilation
iex> mix.
iex> recompile()

# Check for syntax errors
iex> c("lib/path/to/file.ex")
```

### Database Issues

**Connection Problems:**
```bash
# Check database status
docker-compose ps postgres

# Reset database
mix ecto.drop
mix ecto.create
mix ecto.migrate
```

## 📚 Advanced Development

### Custom Mix Tasks

```elixir
# lib/mix/tasks/arbor.analyze.ex
defmodule Mix.Tasks.Arbor.Analyze do
  use Mix.Task
  
  @shortdoc "Analyze Arbor system performance"
  
  def run(args) do
    Mix.Task.run("app.start")
    # Analysis logic
  end
end
```

### Development Utilities

**Process Monitoring:**
```elixir
defmodule Arbor.Dev.ProcessMonitor do
  def monitor_agents do
    agents = Arbor.Core.list_agents()
    
    Enum.each(agents, fn agent ->
      info = Process.info(agent.pid)
      IO.puts("Agent #{agent.id}: #{inspect(info)}")
    end)
  end
end
```

**Development Fixtures:**
```elixir
defmodule Arbor.Dev.Fixtures do
  def create_test_agents(count \\ 10) do
    1..count
    |> Enum.map(fn i ->
      Arbor.Core.spawn_agent(:test_agent, %{id: "test_#{i}"})
    end)
  end
end
```

## 🚀 Release Management

### Development Releases

```bash
# Build development release
./scripts/release.sh --env dev

# Test release locally
_build/dev/rel/arbor/bin/arbor start
```

### Production Releases

```bash
# Build production release
./scripts/release.sh --env prod --version 1.0.0

# Create release package
./scripts/release.sh --package
```

## 🔗 Additional Resources

### Learning Materials
- [Elixir Official Docs](https://elixir-lang.org/docs.html)
- [OTP Design Principles](https://www.erlang.org/doc/design_principles/users_guide.html)
- [Phoenix Framework](https://phoenixframework.org/) (for web interface components)

### Community Resources
- [Elixir Forum](https://elixirforum.com/)
- [ElixirLang Slack](https://elixir-lang.slack.com/)
- [BEAM Community Discord](https://discord.gg/beam-community)

### Arbor-Specific Documentation
- [Architecture Overview](architecture.md)
- [Contributing Guidelines](../CONTRIBUTING.md)
- [CI/CD Pipeline](../.github/README.md)
- [Scripts Reference](../scripts/README.md)

---

Happy coding! 🌳✨

This development guide should cover most scenarios you'll encounter while working with Arbor. If you have questions or run into issues not covered here, please check our [Contributing Guidelines](../CONTRIBUTING.md) or reach out to the community.