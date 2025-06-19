# Contributing to Arbor

Welcome! We're thrilled that you want to contribute to **Arbor**, the distributed AI agent orchestration system. This document provides guidelines and information to help you contribute effectively.

## 📜 Code of Conduct

By participating in this project, you agree to abide by our [Code of Conduct](#code-of-conduct-details). We are committed to providing a welcoming and inspiring community for all.

### Our Standards

**Examples of behavior that contributes to a positive environment:**
- Using welcoming and inclusive language
- Being respectful of differing viewpoints and experiences
- Gracefully accepting constructive criticism
- Focusing on what is best for the community
- Showing empathy towards other community members

**Examples of unacceptable behavior:**
- The use of sexualized language or imagery
- Trolling, insulting/derogatory comments, and personal or political attacks
- Public or private harassment
- Publishing others' private information without explicit permission
- Other conduct which could reasonably be considered inappropriate in a professional setting

## 🚀 Getting Started

### Prerequisites

Before contributing, ensure you have:
- **Elixir 1.15.7+** and **OTP 26.1+**
- **Git** configured with your name and email
- **GitHub account** for pull requests
- **asdf** (recommended) for version management

### Development Setup

1. **Fork the repository** on GitHub
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/arbor.git
   cd arbor
   ```
3. **Add upstream remote**:
   ```bash
   git remote add upstream https://github.com/azmaveth/arbor.git
   ```
4. **Run initial setup**:
   ```bash
   ./scripts/setup.sh
   ```
5. **Verify everything works**:
   ```bash
   ./scripts/test.sh
   ```

### Development Workflow

```bash
# Start development server
./scripts/dev.sh

# In another terminal, run tests frequently
./scripts/test.sh --fast

# Generate coverage reports
./scripts/test.sh --coverage

# Performance benchmarks (when optimizing)
./scripts/benchmark.sh
```

## 🔧 Development Guidelines

### Code Style

We follow **Elixir community conventions** with some specific guidelines:

#### Formatting
- Use `mix format` for automatic code formatting
- Lines should not exceed 98 characters
- Use 2 spaces for indentation (no tabs)

#### Naming Conventions
```elixir
# Modules: PascalCase
defmodule Arbor.Core.AgentSupervisor do

# Functions and variables: snake_case
def spawn_agent(agent_type, params) do

# Constants: SCREAMING_SNAKE_CASE
@default_timeout 5_000

# Private functions: snake_case with defp
defp validate_params(params) do
```

#### Documentation
- All public functions **MUST** have `@doc` annotations
- Use `@moduledoc` for module-level documentation
- Include examples in documentation when helpful
- Use `@spec` for function type specifications

```elixir
@doc """
Spawns a new agent with the given type and parameters.

## Parameters
- `agent_type`: The type of agent to spawn (atom)
- `params`: Configuration parameters (map)

## Returns
- `{:ok, agent_id}` on success
- `{:error, reason}` on failure

## Examples

    iex> Arbor.Core.spawn_agent(:task_executor, %{max_tasks: 5})
    {:ok, "agent_123"}
"""
@spec spawn_agent(atom(), map()) :: {:ok, String.t()} | {:error, term()}
def spawn_agent(agent_type, params) do
```

### Testing Requirements

#### Test Coverage
- **Minimum 80%** coverage across all applications
- **Property-based tests** for complex logic using StreamData
- **Integration tests** for component interactions
- **Performance tests** for critical paths

#### Test Organization
```elixir
defmodule Arbor.Core.AgentSupervisorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  
  doctest Arbor.Core.AgentSupervisor
  
  describe "spawn_agent/2" do
    test "spawns agent successfully with valid parameters" do
      # Test implementation
    end
    
    property "handles various parameter combinations" do
      # Property-based test
    end
  end
  
  describe "terminate_agent/1" do
    # More tests
  end
end
```

#### Testing Best Practices
- Use descriptive test names that explain the expected behavior
- Follow the **Arrange-Act-Assert** pattern
- Use `async: true` for tests that don't share state
- Mock external dependencies using `:meck` or `:hammox`
- Test error conditions and edge cases

### Architecture Guidelines

#### Umbrella Applications
Arbor follows a **contracts-first architecture** with clear boundaries:

```text
arbor_contracts (no dependencies)
    ↑
arbor_security ← arbor_persistence
    ↑               ↑
arbor_core ←--------┘
```

**Rules:**
- `arbor_contracts` has **zero dependencies** (foundational schemas/types)
- Dependencies flow **upward only** (no circular dependencies)
- Each app has a **single, clear responsibility**
- Inter-app communication via **well-defined contracts**

#### OTP Principles
- **Supervision trees** for fault tolerance
- **GenServer/GenStateMachine** for stateful processes
- **"Let it crash"** philosophy with proper error handling
- **Defensive programming** with comprehensive guards

#### Security First
- **Capability-based security** for all resource access
- **Input validation** at application boundaries
- **Audit logging** for security-relevant events
- **Principle of least privilege** throughout

### Git Workflow

#### Branch Naming
```bash
# Feature branches
feature/agent-hot-swapping
feature/distributed-tracing

# Bug fixes
bugfix/memory-leak-in-agent-pool
bugfix/capability-grant-race-condition

# Documentation
docs/contributing-guidelines
docs/architecture-overview

# Hotfixes
hotfix/security-vulnerability-cve-2024-001
```

#### Commit Messages
We use **Conventional Commits** format:

```text
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, etc.)
- `refactor`: Code refactoring
- `perf`: Performance improvements
- `test`: Adding or modifying tests
- `chore`: Maintenance tasks
- `ci`: CI/CD changes

**Examples:**
```bash
feat(core): add agent hot-swapping capability

Implements dynamic agent replacement without state loss.
Includes supervision tree updates and state migration.

Closes #123

fix(security): prevent capability privilege escalation

Ensures capability grants cannot exceed granter's permissions.
Adds validation in capability kernel with comprehensive tests.

BREAKING CHANGE: capability grant API now requires explicit permission validation

docs: update contributing guidelines with architecture section

perf(persistence): optimize event store batch operations
```

## 🎯 Types of Contributions

### 🐛 Bug Reports

When reporting bugs, please include:

1. **Clear description** of the issue
2. **Steps to reproduce** the problem
3. **Expected vs. actual behavior**
4. **Environment information** (Elixir/OTP versions, OS)
5. **Relevant logs** or error messages
6. **Minimal reproduction** case if possible

Use our **bug report template**:

```markdown
## Bug Description
Brief description of the issue.

## Steps to Reproduce
1. Start Arbor with `./scripts/dev.sh`
2. Execute command: `Arbor.Core.spawn_agent(:invalid_type, %{})`
3. Observe error

## Expected Behavior
Should return `{:error, :invalid_agent_type}`

## Actual Behavior
Process crashes with `ArgumentError`

## Environment
- Elixir: 1.15.7
- OTP: 26.1
- OS: macOS 14.0
- Arbor version: 0.1.0

## Additional Context
Error occurs only when using invalid atom types.
```

### ✨ Feature Requests

For new features, please:

1. **Check existing issues** to avoid duplicates
2. **Describe the use case** and motivation
3. **Propose a solution** or approach
4. **Consider alternatives** you've explored
5. **Discuss impact** on existing functionality

### 🔧 Code Contributions

#### Pull Request Process

1. **Create a feature branch** from `main`
2. **Make your changes** following our guidelines
3. **Add/update tests** for your changes
4. **Update documentation** as needed
5. **Run the full test suite**: `./scripts/test.sh`
6. **Commit with conventional messages**
7. **Push to your fork** and create a Pull Request

#### Pull Request Template

```markdown
## Description
Brief description of changes made.

## Type of Change
- [ ] Bug fix (non-breaking change fixing an issue)
- [ ] New feature (non-breaking change adding functionality)
- [ ] Breaking change (fix or feature causing existing functionality to change)
- [ ] Documentation update

## Testing
- [ ] Tests pass locally
- [ ] New tests added for changes
- [ ] Coverage maintained/improved

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] No merge conflicts
```

### 📚 Documentation

Documentation improvements are always welcome:

- **API documentation** improvements
- **Tutorial additions** or enhancements
- **Architecture explanations** 
- **Example applications**
- **Troubleshooting guides**

## 🔍 Code Review Process

### Review Criteria

We review PRs for:

1. **Functionality**: Does it work as intended?
2. **Testing**: Adequate test coverage and quality?
3. **Code Quality**: Clean, readable, maintainable?
4. **Architecture**: Follows project patterns and principles?
5. **Documentation**: Properly documented?
6. **Security**: No security vulnerabilities introduced?
7. **Performance**: No significant performance regressions?

### Review Timeline

- **Initial feedback**: Within 2 business days
- **Code review**: Within 5 business days  
- **Final approval**: When all feedback addressed

### Addressing Feedback

When reviewers provide feedback:

1. **Read carefully** and ask clarifying questions if needed
2. **Make requested changes** in separate commits
3. **Reply to comments** explaining your changes
4. **Re-request review** when ready
5. **Be patient and respectful** throughout the process

## 🚀 Release Process

### Version Strategy

We follow **Semantic Versioning** (SemVer):
- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

### Pre-1.0 Releases

During alpha development (v0.x.x):
- **Minor versions** may include breaking changes
- **Patch versions** are for bug fixes only
- Breaking changes are **clearly documented**

## 🆘 Getting Help

### Questions and Support

- **GitHub Discussions**: General questions and community discussion
- **GitHub Issues**: Bug reports and feature requests
- **Discord**: Real-time community chat (coming soon)
- **Email**: [azmaveth@example.com](mailto:azmaveth@example.com) for sensitive issues

### Development Help

If you're stuck during development:

1. **Check the documentation** in `docs/`
2. **Search existing issues** on GitHub
3. **Ask in GitHub Discussions**
4. **Join our Discord** community
5. **Read the source code** - it's well documented!

## 🎉 Recognition

### Contributors

All contributors are recognized in:
- **CONTRIBUTORS.md** file
- **GitHub contributors** section
- **Release notes** for significant contributions
- **Annual contributor awards** (coming soon)

### Types of Recognition

- **Code Contributors**: Direct code contributions
- **Documentation Contributors**: Improving docs and guides
- **Community Contributors**: Helping others, organizing events
- **Bug Hunters**: Finding and reporting issues
- **Reviewers**: Providing thoughtful code reviews

## 📋 Checklist for New Contributors

Before your first contribution:

- [ ] Read this contributing guide completely
- [ ] Set up development environment successfully
- [ ] Run tests and ensure they pass
- [ ] Read the architecture documentation
- [ ] Join GitHub Discussions
- [ ] Fork the repository
- [ ] Create a small test contribution (typo fix, doc improvement)

## 🔗 Additional Resources

### Elixir Learning Resources
- [Elixir Official Guide](https://elixir-lang.org/getting-started/introduction.html)
- [OTP Design Principles](https://www.erlang.org/doc/design_principles/users_guide.html)
- [Learn You Some Erlang](https://learnyousomeerlang.com/)

### Project-Specific Documentation
- [Architecture Overview](docs/architecture.md)
- [Development Guide](docs/development.md)
- [API Documentation](doc/index.html) (generate with `mix docs`)
- [Scripts Reference](scripts/README.md)

### Community
- [Elixir Forum](https://elixirforum.com/)
- [ElixirLang Slack](https://elixir-lang.slack.com/)
- [BEAM Community Discord](https://discord.gg/beam-community)

---

## Code of Conduct Details

### Our Pledge

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone, regardless of age, body size, visible or invisible disability, ethnicity, sex characteristics, gender identity and expression, level of experience, education, socio-economic status, nationality, personal appearance, race, religion, or sexual identity and orientation.

### Our Responsibilities

Project maintainers are responsible for clarifying the standards of acceptable behavior and are expected to take appropriate and fair corrective action in response to any instances of unacceptable behavior.

### Enforcement

Instances of abusive, harassing, or otherwise unacceptable behavior may be reported by contacting the project team at [azmaveth@example.com](mailto:azmaveth@example.com). All complaints will be reviewed and investigated promptly and fairly.

---

**Thank you for contributing to Arbor!** 🌳

Your contributions help make distributed AI agent orchestration accessible, reliable, and secure for everyone.