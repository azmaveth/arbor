# Arbor Phase 1: Minimum Viable Product Implementation Plan

## Overview

This plan provides a complete roadmap for setting up Arbor as a production-ready distributed AI agent orchestration system, with detailed AI prompts for each implementation step.

## Project Structure

```text
arbor/
├── apps/
│   ├── arbor_contracts/    # Zero-dependency contracts & behaviours
│   ├── arbor_security/     # Capability-based security
│   ├── arbor_persistence/  # State management & event sourcing
│   └── arbor_core/         # Core business logic & gateway
├── config/                 # Shared configuration
├── scripts/                # Development & deployment scripts
├── .github/                # CI/CD workflows
└── docs/                   # Project documentation
```

## Phase 1 Implementation Steps

### Step 1: Project Initialization

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:
- `docs/arbor/01-overview/umbrella-structure.md` - Study the detailed project structure requirements
- `docs/arbor/01-overview/architecture-overview.md` - Understand system architecture principles
- `docs/arbor/03-contracts/README.md` - Learn the Contracts-First design approach

BEFORE STARTING: Verify all prerequisites are met - check that Elixir 1.15+, Erlang/OTP 26+, Mix, and Git are installed and available.

Create an Elixir umbrella project structure for Arbor as defined in the reference documentation. Start by creating the zero-dependency `arbor_contracts` application first, followed by `arbor_security`, `arbor_persistence`, and `arbor_core`, ensuring the dependency flow described in the documentation is respected. Each app should have supervision trees. Create a comprehensive .gitignore file for Elixir projects. The structure must follow the Contracts-First design principle.

AFTER COMPLETION: Verify all postrequisites are achieved - confirm umbrella project created with 4 supervised applications in correct dependency order, arbor_contracts as zero-dependency foundation, git repository initialized with initial commit, and .gitignore properly configured."

**Reference Documentation:**

- [Umbrella Structure](../01-overview/umbrella-structure.md) - Detailed project structure
- [Architecture Overview](../01-overview/architecture-overview.md) - System architecture principles
- [Contracts README](../03-contracts/README.md) - Contracts-First design approach

**Prerequisites:**

- Elixir 1.15+ and Erlang/OTP 26+ installed
- Mix available in PATH
- Git installed

**Commands:**

```bash
# Create project directory
mkdir arbor && cd arbor

# Initialize umbrella project
mix new . --umbrella --module Arbor

# Create initial app structure following dependency order
cd apps
mix new arbor_contracts --module Arbor.Contracts --sup
mix new arbor_security --module Arbor.Security --sup
mix new arbor_persistence --module Arbor.Persistence --sup
mix new arbor_core --module Arbor.Core --sup
cd ..

# Initialize git repository
git init
git add .
git commit -m "chore: initialize Arbor umbrella project"
```

**Postrequisites:**

- Umbrella project created with 4 supervised applications in correct dependency order
- arbor_contracts as zero-dependency foundation application
- Git repository initialized with initial commit
- .gitignore properly configured for Elixir/Erlang

---

### Step 2: Development Environment and Git Hooks Setup

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:
- `docs/arbor/02-philosophy/beam-philosophy.md` - Study the defensive architecture principles that guide quality tooling choices

BEFORE STARTING: Verify prerequisites are met - confirm git repository is initialized and mix project structure exists.

Set up git pre-commit hooks to enforce the project's quality standards. The hooks should automate the validation of code formatting, static analysis (credo), and type safety (dialyzer), reflecting the 'defensive architecture' principles from the reference documentation. Also, create a `.tool-versions` file for asdf version management with Elixir 1.15.7 and Erlang 26.1, and a conventional commit message template as specified.

AFTER COMPLETION: Verify postrequisites are achieved - confirm pre-commit hook validates code quality, commit message template enforces conventional commits, and version management is configured with .tool-versions."

**Reference Documentation:**

- [BEAM Philosophy](../02-philosophy/beam-philosophy.md) - Defensive architecture principles

**Prerequisites:**

- Git repository initialized
- Mix project structure exists

**Commands and Configuration:**

```bash
# Install pre-commit hooks
cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
set -e
echo "Running pre-commit checks..."

# Format code
mix format --check-formatted
if [ $? -ne 0 ]; then
    echo "Code formatting issues found. Running mix format..."
    mix format
    echo "Please review and stage formatting changes."
    exit 1
fi

# Run credo
mix credo --strict
if [ $? -ne 0 ]; then
    echo "Credo found issues. Please fix before committing."
    exit 1
fi

# Run dialyzer
mix dialyzer
if [ $? -ne 0 ]; then
    echo "Dialyzer found type issues. Please fix before committing."
    exit 1
fi

# Run tests
mix test
if [ $? -ne 0 ]; then
    echo "Tests failed. Please fix before committing."
    exit 1
fi

echo "All pre-commit checks passed!"
EOF

chmod +x .git/hooks/pre-commit

# Setup commit message template
cat > .gitmessage << 'EOF'
# <type>(<scope>): <subject>
#
# <body>
#
# <footer>
#
# Type: feat, fix, docs, style, refactor, test, chore
# Scope: core, persistence, security, telemetry, deps
# Subject: imperative mood, max 50 chars
# Body: explain what and why, not how
# Footer: breaking changes, issues closed
EOF

git config commit.template .gitmessage
```

**Postrequisites:**

- Pre-commit hook validates code quality
- Commit message template enforces conventional commits
- Version management configured with .tool-versions

---

### Step 3: Development Dependencies and Quality Tools

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/06-infrastructure/tooling-analysis.md` - Study the recommended development tools and their rationale
- `docs/arbor/02-philosophy/beam-philosophy.md` - Understand defensive architecture principles for tool selection

BEFORE STARTING: Verify prerequisites are met - confirm umbrella project structure exists and mix.exs files are created for each app.

Configure the development dependencies for the Arbor umbrella project, selecting the tools recommended in the reference documentation. Ensure `credo` and `dialyxir` are included to support the project's 'defensive architecture' principles. Add ex_doc for documentation, excoveralls for test coverage, mock and ex_machina for testing, observer_cli for runtime inspection, and benchee for performance testing. Create the mix aliases as specified in the implementation plan. Configure excoveralls to generate coverage reports in HTML and JSON formats.

AFTER COMPLETION: Verify postrequisites are achieved - confirm all development dependencies are configured, mix aliases for common tasks are available, test coverage reporting is configured, and documentation generation is ready."

**Reference Documentation:**

- [Tooling Analysis](../06-infrastructure/tooling-analysis.md) - Recommended development tools
- [BEAM Philosophy](../02-philosophy/beam-philosophy.md) - Defensive architecture principles

**Prerequisites:**

- Umbrella project structure exists
- mix.exs files created for each app

**Mix Dependencies Configuration:**

```elixir
# In root mix.exs
defp deps do
  [
    # Code quality
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:ex_doc, "~> 0.31", only: :dev, runtime: false},
    
    # Testing
    {:excoveralls, "~> 0.18", only: :test},
    {:mock, "~> 0.3", only: :test},
    {:ex_machina, "~> 2.7", only: :test},
    
    # Development tools
    {:observer_cli, "~> 1.7", only: :dev},
    {:benchee, "~> 1.3", only: :dev}
  ]
end

# Configure aliases
defp aliases do
  [
    setup: ["deps.get", "deps.compile", "compile"],
    "test.all": ["test --cover", "credo --strict", "dialyzer"],
    "test.ci": ["test --cover --export-coverage default", "credo --strict"],
    docs: ["docs", "cmd --app arbor_core mix docs", "cmd --app arbor_persistence mix docs"],
    quality: ["format", "credo --strict", "dialyzer"]
  ]
end
```

**Postrequisites:**

- All development dependencies configured
- Mix aliases for common tasks available
- Test coverage reporting configured
- Documentation generation ready

---

### Step 4: Convenience Scripts and Development Workflow

**AI Implementation Prompt:**
"FIRST: Read and understand the overall project workflow from previous steps to ensure scripts align with the established development patterns.

BEFORE STARTING: Verify prerequisites are met - confirm project structure with mix.exs is configured and development dependencies are defined.

Create a comprehensive set of development scripts for the Arbor project in a scripts/ directory. Include: setup.sh (initial project setup with dependency installation and dialyzer PLT building), dev.sh (start development server with distributed node), test.sh (run full test suite), console.sh (connect to running node), release.sh (build production release), and benchmark.sh (run performance benchmarks). Each script should have proper error handling, helpful output messages, and check for prerequisites.

AFTER COMPLETION: Verify postrequisites are achieved - confirm executable scripts are in scripts/ directory, development workflow is streamlined, and easy onboarding is available for new developers."

**Prerequisites:**

- Project structure with mix.exs configured
- Development dependencies defined

**Create Development Scripts:**

```bash
# Create scripts directory
mkdir scripts

# scripts/setup.sh
cat > scripts/setup.sh << 'EOF'
#!/bin/bash
set -e

echo "Setting up Arbor development environment..."

# Check prerequisites
command -v elixir >/dev/null 2>&1 || { echo "Elixir is required but not installed."; exit 1; }
command -v mix >/dev/null 2>&1 || { echo "Mix is required but not installed."; exit 1; }

# Install dependencies
mix deps.get
mix deps.compile

# Setup dialyzer
mix dialyzer --plt

# Run initial quality checks
mix quality

echo "Setup complete! Run 'scripts/dev.sh' to start development."
EOF

# scripts/dev.sh
cat > scripts/dev.sh << 'EOF'
#!/bin/bash
# Start interactive development session
iex -S mix phx.server --name arbor@localhost --cookie arbor_dev
EOF

# scripts/test.sh
cat > scripts/test.sh << 'EOF'
#!/bin/bash
# Run comprehensive test suite
mix test.all
EOF

# scripts/console.sh
cat > scripts/console.sh << 'EOF'
#!/bin/bash
# Connect to running node
iex --name console@localhost --cookie arbor_dev --remsh arbor@localhost
EOF

chmod +x scripts/*.sh
```

**Postrequisites:**

- Executable scripts in scripts/ directory
- Streamlined development workflow
- Easy onboarding for new developers

---

### Step 5: CI/CD Pipeline Foundation

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/06-infrastructure/observability.md` - Study the production monitoring and telemetry requirements that guide CI/CD design

BEFORE STARTING: Verify prerequisites are met - confirm git repository with project structure exists and test suite and quality tools are configured.

Set up a GitHub Actions CI/CD pipeline for the Arbor project. The pipeline must run the `test.ci` mix alias and upload coverage reports, supporting the project's observability goals from the reference documentation. Create workflows for: 1) CI testing on push/PR (format check, credo, tests, coverage), 2) Nightly builds with dialyzer and security scanning, 3) Release workflow for tagged versions. Include dependency caching, matrix testing for multiple Elixir/OTP versions, and integration with codecov for coverage reports. Also create a Dockerfile for containerized deployments.

AFTER COMPLETION: Verify postrequisites are achieved - confirm GitHub Actions workflows are configured, automated testing runs on every push/PR, coverage reporting is integrated, and release automation is ready."

**Reference Documentation:**

- [Observability](../06-infrastructure/observability.md) - Production monitoring and telemetry requirements

**Prerequisites:**

- Git repository with project structure
- Test suite and quality tools configured

**GitHub Actions Workflow:**

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ubuntu-latest
    
    strategy:
      matrix:
        elixir: ['1.15.7']
        otp: ['26.1']
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Setup Elixir
      uses: erlef/setup-beam@v1
      with:
        elixir-version: ${{ matrix.elixir }}
        otp-version: ${{ matrix.otp }}
    
    - name: Restore dependencies cache
      uses: actions/cache@v3
      with:
        path: |
          deps
          _build
          priv/plts
        key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}
        restore-keys: ${{ runner.os }}-mix-
    
    - name: Install dependencies
      run: mix deps.get
    
    - name: Check formatting
      run: mix format --check-formatted
    
    - name: Run credo
      run: mix credo --strict
    
    - name: Run tests
      run: mix test.ci
    
    - name: Upload coverage
      uses: codecov/codecov-action@v3
      with:
        files: ./cover/excoveralls.json
```

**Postrequisites:**

- GitHub Actions workflows configured
- Automated testing on every push/PR
- Coverage reporting integrated
- Release automation ready

---

### Step 6: Documentation and README Setup

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/README.md` - Study the overall documentation organization and structure requirements

BEFORE STARTING: Verify prerequisites are met - confirm project structure is established and scripts are created.

Create the initial documentation files for the Arbor project. The overall structure of the `docs/` directory should mirror the table of contents from the reference documentation. Create: 1) Main README.md with project overview, features, quick start, and structure, 2) CONTRIBUTING.md with contribution guidelines, code of conduct, and PR process, 3) docs/development.md with detailed development setup, 4) docs/architecture.md explaining the system design, 5) LICENSE file (MIT), and 6) .editorconfig for consistent code style across editors.

AFTER COMPLETION: Verify postrequisites are achieved - confirm comprehensive documentation exists, clear onboarding path is available, contribution guidelines are defined, and license is established."

**Reference Documentation:**

- [Arbor Documentation Structure](../README.md) - Overall documentation organization

**Prerequisites:**

- Project structure established
- Scripts created

**Create Comprehensive Documentation:**

```markdown
# README.md
# Arbor - Distributed AI Agent Orchestration System

Arbor is a production-ready, distributed AI agent orchestration system built on Elixir/OTP principles.

## Features

- **Distributed Architecture**: Built on BEAM VM for fault-tolerance and scalability
- **Agent Orchestration**: Coordinate multiple AI agents with different capabilities
- **Capability-Based Security**: Fine-grained permissions and access control
- **State Persistence**: Reliable state management with event sourcing
- **Observability**: Built-in telemetry and monitoring

## Quick Start

```bash
# Clone the repository
git clone https://github.com/azmaveth/arbor.git
cd arbor

# Run setup
./scripts/setup.sh

# Start development server
./scripts/dev.sh
```

## Directory Structure

```text
arbor/
├── apps/
│   ├── arbor_core/        # Core business logic
│   ├── arbor_persistence/  # State management
│   ├── arbor_security/     # Security layer
│   └── arbor_telemetry/    # Observability
├── config/                 # Configuration files
├── scripts/               # Development scripts
└── docs/                  # Documentation
```

## Development

See [docs/development.md](docs/development.md) for detailed development instructions.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines.

## Project License

This project is licensed under the MIT License - see [LICENSE](LICENSE) file.

**Postrequisites:**

- Comprehensive documentation
- Clear onboarding path
- Contribution guidelines
- License defined

---

### Step 7: Initial Core Implementation - Gateway Pattern

**AI Implementation Prompt:**
"FIRST: Read and understand all reference documentation:

- `docs/arbor/04-components/arbor-core/specification.md` - Study the complete core component architecture requirements
- `docs/arbor/04-components/arbor-core/gateway-patterns.md` - Learn the Gateway pattern and Event-Driven Updates implementation details
- `docs/arbor/03-contracts/core-contracts.md` - Understand agent behaviour and contract definitions that must be implemented in arbor_contracts

BEFORE STARTING: Verify prerequisites are met - confirm arbor_core application is created and dependencies are configured.

Implement the initial `arbor_core` modules based on the architecture defined in the reference documentation. Your implementation must follow the **Gateway Pattern** and **Event-Driven Updates** flow as specified. Create: 1) Arbor.Core.Gateway as the single entry point for client interactions, 2) Arbor.Core.Session for session management, 3) Arbor.Core.Supervisor to manage the supervision tree. The `Arbor.Agent` behaviour should be defined within the `arbor_contracts` application, as specified in the contracts documentation. Include proper error handling, telemetry events, and structured logging.

AFTER COMPLETION: Verify postrequisites are achieved - confirm Gateway pattern is implemented following documented architecture, Agent behaviour is defined in arbor_contracts application, session management uses event-driven updates, and supervision tree is structured according to specifications."

**Reference Documentation:**

- [Arbor Core Specification](../04-components/arbor-core/specification.md) - Core component architecture
- [Gateway Patterns](../04-components/arbor-core/gateway-patterns.md) - Gateway pattern implementation details
- [Core Contracts](../03-contracts/core-contracts.md) - Agent behaviour and contract definitions

**Prerequisites:**

- arbor_core application created
- Dependencies configured

**Create Core Foundation:**

```elixir
# apps/arbor_core/lib/arbor/core/gateway.ex
defmodule Arbor.Core.Gateway do
  @moduledoc """
  Central entry point for all Arbor operations.
  Implements the Gateway pattern for API consistency.
  """
  
  use GenServer
  require Logger
  
  # Client API
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def create_session(params) do
    GenServer.call(__MODULE__, {:create_session, params})
  end
  
  def send_message(session_id, message) do
    GenServer.call(__MODULE__, {:send_message, session_id, message})
  end
  
  # Server callbacks
  def init(opts) do
    {:ok, %{sessions: %{}, opts: opts}}
  end
  
  def handle_call({:create_session, params}, _from, state) do
    session_id = generate_session_id()
    # TODO: Implement session creation logic
    {:reply, {:ok, session_id}, state}
  end
  
  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16()
  end
end
```

**Postrequisites:**

- Gateway pattern implemented following documented architecture
- Agent behaviour defined in arbor_contracts application
- Session management with event-driven updates
- Supervision tree structured according to specifications

---

## Workflow Diagram

```text
   Project Setup
        |
        v
   [Step 1: Initialize]
        |
        v
   [Step 2: Git Hooks]
        |
        v
   [Step 3: Dependencies]
        |
        v
   [Step 4: Scripts]
        |
        v
   [Step 5: CI/CD]
        |
        v
   [Step 6: Documentation]
        |
        v
   [Step 7: Core Implementation]
        |
        v
    MVP Complete
```

## Summary

This Phase 1 MVP implementation plan provides:

1. **Complete project setup** with umbrella structure
2. **Development environment** with quality tools and git hooks
3. **Automated workflows** through convenience scripts
4. **CI/CD pipeline** for quality assurance
5. **Comprehensive documentation** for onboarding
6. **Initial core implementation** with Gateway pattern

Each step includes:

- Clear prerequisites and postrequisites
- Exact commands to execute
- Detailed AI prompts for implementation
- Expected outcomes

This foundation ensures Arbor starts with production-ready practices from day one, setting the stage for scalable development of the distributed AI agent orchestration system.
