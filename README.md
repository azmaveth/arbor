# This repository has moved

This project has moved to [trust-arbor/arbor](https://github.com/trust-arbor/arbor). Development continues there.

---

# Arbor - Distributed AI Agent Orchestration System

[![CI](https://github.com/azmaveth/arbor/workflows/CI/badge.svg)](https://github.com/azmaveth/arbor/actions/workflows/ci.yml)
[![Release](https://github.com/azmaveth/arbor/workflows/Release/badge.svg)](https://github.com/azmaveth/arbor/actions/workflows/release.yml)
[![Coverage](https://codecov.io/gh/azmaveth/arbor/branch/main/graph/badge.svg)](https://codecov.io/gh/azmaveth/arbor)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> ⚠️ **Alpha Software**: This project is currently in alpha stage (v0.x.x).
> The API is unstable and may change significantly before v1.0 release.
> See [PROJECT_STATUS.md](docs/PROJECT_STATUS.md) for current implementation status.

**Arbor** is an ambitious distributed AI agent orchestration system built on the rock-solid foundation of Elixir/OTP. Designed from the ground up for fault-tolerance, scalability, and security, Arbor aims to enable sophisticated multi-agent AI workflows with enterprise-grade reliability.

> **Current State**: Core infrastructure is implemented including distributed agent supervision, capability-based security, and event sourcing. The CLI and AI integrations are still under development.

## 🌟 Key Features

### 🏗️ **Distributed Architecture**
- **BEAM VM Foundation**: Built on Erlang/OTP for legendary fault-tolerance and concurrency
- **Umbrella Project**: Modular design with clear separation of concerns
- **Horde Integration**: Dynamic process distribution across cluster nodes
- **Defensive Programming**: "Let it crash" philosophy with comprehensive supervision trees

### 🤖 **AI Agent Orchestration**
- **Multi-Agent Coordination**: Orchestrate diverse AI agents with different capabilities
- **Dynamic Agent Spawning**: Create and manage agents based on workload demands
- **Inter-Agent Communication**: Robust message passing with trace correlation
- **Task Delegation**: Intelligent work distribution across agent types

### 🔒 **Capability-Based Security**
- **Fine-Grained Permissions**: Resource-specific access controls with time-based expiration
- **Zero-Trust Architecture**: Every operation requires explicit capability grants
- **Audit Trail**: Complete security event logging for compliance
- **Principle of Least Privilege**: Minimal permission grants with automatic revocation

### 💾 **State Persistence & Recovery**
- **Event Sourcing**: Immutable event streams for complete state reconstruction
- **CQRS Pattern**: Optimized read/write models for performance
- **Automatic Recovery**: Self-healing systems with state restoration
- **Distributed State**: Consistent state management across cluster nodes

### 📊 **Production-Ready Observability**
- **Three Pillars**: Comprehensive metrics, structured logs, and distributed traces
- **OpenTelemetry Integration**: Industry-standard telemetry and tracing
- **Real-Time Monitoring**: Prometheus metrics with Grafana dashboards
- **Performance Analytics**: Detailed insights into agent behavior and system health

## 🚀 Quick Start

### Prerequisites
- **Elixir 1.15.7+** and **OTP 26.1+**
- **Git** for version control
- **Docker & Docker Compose** (optional, for observability stack)

### Installation

```bash
# Clone the repository
git clone https://github.com/azmaveth/arbor.git
cd arbor

# Run one-time setup (installs dependencies, builds PLT files)
./scripts/setup.sh

# Start development server with distributed node capabilities
./scripts/dev.sh
```

### Development Workflow

```bash
# Run comprehensive test suite
./scripts/test.sh

# Quick feedback loop (skip slow checks)
./scripts/test.sh --fast

# Generate coverage report
./scripts/test.sh --coverage

# Connect to running development node (in another terminal)
./scripts/console.sh

# Performance benchmarks
./scripts/benchmark.sh

# Run distributed tests (multi-node cluster tests)
./scripts/test-distributed.sh
```

### Testing Infrastructure

Arbor uses a **hybrid testing approach** that balances fast feedback with comprehensive distributed system verification:

- **Single-node tests** (default): Fast unit and integration tests that run in isolation
- **Distributed tests** (`@tag :distributed`): Multi-node tests that verify cluster behavior

#### Distributed Testing Capabilities

The distributed test suite validates critical distributed system behaviors:

- **CRDT Synchronization**: Ensures distributed data structures converge correctly across nodes
- **Failover Scenarios**: Verifies agents migrate properly when nodes crash
- **Race Condition Handling**: Tests concurrent operations maintain consistency
- **Split-Brain Recovery**: Validates cluster healing after network partitions

Test helpers in `test/support/` provide utilities for:
- Multi-node cluster orchestration
- Network partition simulation
- Cascading failure scenarios
- CRDT convergence verification
- Race condition detection

### Using Docker

```bash
# Development environment with full observability stack
docker-compose up -d

# Access services:
# - Arbor: http://localhost:4000
# - Grafana: http://localhost:3000 (admin/admin)
# - Prometheus: http://localhost:9090
# - Jaeger: http://localhost:16686

# Build production image
docker build -t arbor:latest .
```

## 🏛️ Architecture Overview

Arbor follows a **contracts-first, defensive architecture** with clear dependency boundaries:

```text
┌─────────────────────────────────────────────────────────────┐
│                        Arbor System                        │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ Arbor Core   │  │   Arbor      │  │     Arbor        │  │
│  │              │◄─┤  Security    │◄─┤   Persistence    │  │
│  │ • Agents     │  │              │  │                  │  │
│  │ • Tasks      │  │ • Capabilities│  │ • Event Store    │  │
│  │ • Sessions   │  │ • Audit       │  │ • State Mgmt     │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│           │                 │                     │        │
│           └─────────────────┼─────────────────────┘        │
│                             │                              │
│                    ┌──────────────┐                        │
│                    │    Arbor     │                        │
│                    │  Contracts   │                        │
│                    │              │                        │
│                    │ • Schemas    │                        │
│                    │ • Types      │                        │
│                    │ • Protocols  │                        │
│                    └──────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

### 📦 Project Structure

```text
arbor/
├── apps/                           # Umbrella applications
│   ├── arbor_contracts/            # 🔗 Zero-dependency contracts
│   │   ├── lib/arbor/contracts/    # Schema definitions and types
│   │   └── test/                   # Contract validation tests
│   ├── arbor_security/             # 🛡️ Capability-based security
│   │   ├── lib/arbor/security/     # Authentication & authorization
│   │   └── test/                   # Security validation tests
│   ├── arbor_persistence/          # 💾 State management
│   │   ├── lib/arbor/persistence/  # Event sourcing & CQRS
│   │   └── test/                   # Persistence tests
│   └── arbor_core/                 # 🧠 Core business logic
│       ├── lib/arbor/core/         # Agent orchestration
│       └── test/                   # Integration tests
├── config/                         # Configuration files
│   ├── config.exs                  # Base configuration
│   ├── dev.exs                     # Development settings
│   ├── test.exs                    # Test environment
│   └── prod.exs                    # Production settings
├── scripts/                        # 🛠️ Development automation
│   ├── setup.sh                    # One-time project setup
│   ├── dev.sh                      # Development server
│   ├── test.sh                     # Test suite runner
│   ├── console.sh                  # Remote console connection
│   ├── release.sh                  # Production builds
│   └── benchmark.sh                # Performance testing
├── .github/                        # 🔄 CI/CD workflows
│   ├── workflows/                  # GitHub Actions
│   │   ├── ci.yml                  # Continuous integration
│   │   ├── nightly.yml             # Comprehensive testing
│   │   └── release.yml             # Automated releases
│   └── README.md                   # CI/CD documentation
├── observability/                  # 📊 Monitoring configuration
│   ├── prometheus.yml              # Metrics collection
│   ├── grafana/                    # Dashboard definitions
│   └── postgres/                   # Database initialization
├── docs/                           # 📚 Documentation
│   ├── development.md              # Development guide
│   └── architecture.md             # System design
├── Dockerfile                      # 🐳 Container definition
├── docker-compose.yml              # Development environment
└── README.md                       # This file
```

## 🧠 Core Concepts

### Agents
**Autonomous AI entities** with specific capabilities and responsibilities. Each agent:
- Runs in its own supervised process
- Has a unique identity and capability set
- Can communicate with other agents via message passing
- Maintains its own state and execution context

### Capabilities
**Granular permissions** that agents must acquire to access resources:
- **Resource-Specific**: Access to files, APIs, databases, etc.
- **Time-Limited**: Automatic expiration for security
- **Auditable**: Complete grant/revoke/usage logging
- **Hierarchical**: Capabilities can delegate sub-capabilities

### Sessions
**Multi-agent coordination contexts** that manage:
- Agent lifecycle and task distribution
- Shared context and memory
- Resource allocation and cleanup
- Performance monitoring and optimization

## 🔧 Configuration

### Environment Variables
```bash
# Development
export MIX_ENV=dev
export ARBOR_NODE_NAME=arbor@localhost
export ARBOR_COOKIE=arbor_dev_cookie

# Observability
export PROMETHEUS_ENDPOINT=http://localhost:9090
export JAEGER_ENDPOINT=http://localhost:14250
export GRAFANA_ENDPOINT=http://localhost:3000

# Security
export ARBOR_SECRET_KEY_BASE="your-secret-key-base"
export ARBOR_CAPABILITY_ENCRYPTION_KEY="your-encryption-key"
```

### Configuration Files
- `config/config.exs` - Base configuration
- `config/dev.exs` - Development overrides
- `config/prod.exs` - Production settings
- `coveralls.json` - Test coverage thresholds

## 🧪 Testing Strategy

### Test Categories
- **Unit Tests**: Individual module testing with mocks
- **Integration Tests**: Component interaction testing
- **Property-Based Tests**: Comprehensive input validation
- **Performance Tests**: Benchmarking and load testing

### Quality Gates
- **Coverage**: ≥80% test coverage across all apps
- **Static Analysis**: Credo compliance with strict checks
- **Type Safety**: Dialyzer verification with success typing
- **Security**: Dependency vulnerability scanning

### Running Tests
```bash
# Full test suite with coverage
./scripts/test.sh --coverage

# Quick feedback loop
./scripts/test.sh --fast

# Specific test files
mix test test/arbor/core/agent_test.exs

# Property-based tests only
mix test --only property

# Integration tests
mix test --only integration
```

## 🚀 Deployment

### Production Build
```bash
# Build optimized release
./scripts/release.sh

# Build with specific version
./scripts/release.sh --version 1.0.0

# Skip tests for faster builds
./scripts/release.sh --skip-tests
```

### Container Deployment
```bash
# Build production image
docker build -t arbor:v1.0.0 .

# Run with clustering
docker run -d \
  --name arbor-node-1 \
  -p 4000:4000 \
  -e NODE_NAME=arbor@node1.cluster.local \
  -e ERLANG_COOKIE=secure_cluster_cookie \
  arbor:v1.0.0
```

### Kubernetes Deployment
See [docs/deployment/kubernetes.md](docs/deployment/kubernetes.md) for detailed Kubernetes configuration.

## 📊 Monitoring & Observability

### Built-in Metrics
- **Agent Lifecycle**: Spawn/termination rates, lifetime distributions
- **Performance**: Operation latency, throughput, error rates
- **Security**: Capability grants/revokes, security violations
- **System Health**: Memory usage, process counts, cluster status

### Dashboards
Pre-configured Grafana dashboards for:
- **System Overview**: Cluster health, resource utilization
- **Agent Performance**: Operation metrics, communication patterns
- **Security Monitoring**: Capability usage, audit events
- **Distributed Tracing**: Request flows across services

### Alerting
Production-ready alerts for:
- **Critical**: Service outages, security breaches
- **High**: Performance degradation, high error rates  
- **Medium**: Resource constraints, operational issues

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md) for:
- **Code of Conduct**: Community standards and expectations
- **Development Setup**: Detailed environment configuration
- **Pull Request Process**: Code review and merge requirements
- **Issue Templates**: Bug reports and feature requests

### Development Process
1. **Fork** the repository
2. **Create** a feature branch (`git checkout -b feature/amazing-feature`)
3. **Make** your changes following our conventions
4. **Test** thoroughly (`./scripts/test.sh`)
5. **Commit** using conventional commits
6. **Push** to your branch (`git push origin feature/amazing-feature`)
7. **Open** a Pull Request

## 📚 Documentation

### Architecture & Design
- [System Architecture](docs/architecture.md) - Comprehensive system design
- [Development Guide](docs/development.md) - Detailed development setup
- [CI/CD Pipeline](.github/CI_CD.md) - Automated workflows
- [Scripts Reference](scripts/README.md) - Development automation

### API Documentation
Generate comprehensive API docs:
```bash
mix docs
open doc/index.html
```

## 📄 License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **Elixir/OTP Community** for the incredible platform
- **BEAM Ecosystem** for fault-tolerant distributed systems
- **OpenTelemetry Project** for observability standards
- **All Contributors** who make this project possible

## 📞 Support

- **Documentation**: [Complete docs](docs/)
- **Issues**: [GitHub Issues](https://github.com/azmaveth/arbor/issues)
- **Discussions**: [GitHub Discussions](https://github.com/azmaveth/arbor/discussions)
- **Email**: [hysun@hysun.com](mailto:hysun@hysun.com)

---

**Built with ❤️ using Elixir/OTP** - *The best platform for distributed, fault-tolerant systems*