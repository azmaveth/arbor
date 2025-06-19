# Arbor Development Scripts

This directory contains convenience scripts for common development tasks in the Arbor project.

## Available Scripts

### 🚀 setup.sh
**Initial project setup and dependency installation**

```bash
scripts/setup.sh
```

Features:
- Checks for required prerequisites (Elixir, Mix, Git)
- Installs Hex and Rebar if needed
- Installs project dependencies
- Builds Dialyzer PLT files
- Runs initial quality checks
- Creates necessary directories

Perfect for first-time setup or after pulling major changes.

### 🔥 dev.sh
**Start development server with distributed node**

```bash
scripts/dev.sh
```

Features:
- Starts IEx with distributed node capabilities
- Sets up node name: `arbor@localhost`
- Uses development cookie: `arbor_dev`
- Enables unicode support
- Ready for remote console connections

### 🧪 test.sh
**Comprehensive test suite runner**

```bash
scripts/test.sh [options]
```

Options:
- `--coverage`: Generate HTML coverage report
- `--verbose`: Show detailed output
- `--fast`: Skip slow checks (Dialyzer)
- `--help`: Show usage information

Features:
- Unit tests with optional coverage
- Code formatting checks
- Static analysis with Credo
- Type checking with Dialyzer
- Documentation generation
- Timing and progress reporting

Examples:
```bash
scripts/test.sh                # Full test suite
scripts/test.sh --fast         # Quick feedback loop
scripts/test.sh --coverage     # With coverage report
```

### 🔌 console.sh
**Connect to running development node**

```bash
scripts/console.sh [options]
```

Options:
- `--node NODE`: Target node (default: arbor@localhost)
- `--cookie COOKIE`: Erlang cookie (default: arbor_dev)
- `--name NAME`: Console node name (default: console@localhost)
- `--help`: Show usage information

Features:
- Checks if target node is reachable
- Connects to running development server
- Enables remote debugging and inspection
- Safe disconnection with Ctrl+C

Must be run while `dev.sh` is active in another terminal.

### 🚀 release.sh
**Production release builder**

```bash
scripts/release.sh [options]
```

Options:
- `--env ENV`: Build environment (default: prod)
- `--skip-tests`: Skip test suite before build
- `--version VER`: Set specific release version
- `--help`: Show usage information

Features:
- Clean production builds
- Dependency compilation for target environment
- Test suite validation (unless skipped)
- Documentation generation
- Release artifact creation
- Version and build metadata

Examples:
```bash
scripts/release.sh                    # Standard production build
scripts/release.sh --env staging      # Staging environment build
scripts/release.sh --version 1.0.0    # Specific version
```

### ⚡ benchmark.sh
**Performance benchmarking suite**

```bash
scripts/benchmark.sh [options]
```

Options:
- `--suite SUITE`: Specific benchmark suite (all, contracts, messaging, persistence)
- `--output DIR`: Save results to directory
- `--format FORMAT`: Output format (console, html, json)
- `--save`: Save results to files
- `--help`: Show usage information

Features:
- Contract validation performance
- Message passing benchmarks
- Persistence layer testing
- Multiple output formats
- Result archiving with timestamps

Examples:
```bash
scripts/benchmark.sh                           # All benchmarks
scripts/benchmark.sh --suite messaging         # Specific suite
scripts/benchmark.sh --save --format html      # HTML report
```

## Development Workflow

### First Time Setup
```bash
# Clone and setup
git clone <repository>
cd arbor
scripts/setup.sh
```

### Daily Development
```bash
# Start development server
scripts/dev.sh

# In another terminal, run tests
scripts/test.sh --fast

# Connect console for debugging
scripts/console.sh
```

### Before Committing
```bash
# Full test suite (triggers pre-commit automatically)
scripts/test.sh --coverage
git add .
git commit -m "your commit message"
```

### Release Process
```bash
# Build and test release
scripts/release.sh

# Performance validation
scripts/benchmark.sh --save
```

## Prerequisites

- Elixir 1.15+ and OTP 26+
- Git
- Optional: asdf for version management

## Environment Variables

The scripts respect these environment variables:
- `MIX_ENV`: Elixir environment (dev/test/prod)
- Standard Elixir/Mix environment variables

## Troubleshooting

### "Command not found" errors
Ensure scripts are executable:
```bash
chmod +x scripts/*.sh
```

### Node connection issues
- Ensure `dev.sh` is running
- Check firewall settings for localhost connections
- Verify cookie and node name consistency

### PLT build failures
- Clear PLT cache: `rm -rf _build/*/dialyxir_*`
- Run `scripts/setup.sh` to rebuild

### Performance tips
- Use `--fast` flag during development
- Run full test suite before commits
- Generate coverage reports periodically
- Benchmark after performance-critical changes

## Integration with Pre-commit Hooks

The scripts work seamlessly with the project's pre-commit hooks:
- `test.sh` functionality is automatically run on commit
- Manual script execution bypasses git hooks
- Use scripts for development feedback loops