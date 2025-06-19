# Arbor CI/CD Pipeline

This directory contains the complete CI/CD pipeline for the Arbor distributed AI agent orchestration system.

## Workflows Overview

### 🔄 ci.yml - Continuous Integration
**Triggers**: Push to main/master/develop branches, Pull requests to main/master
**Purpose**: Quality gates for every code change

**Features**:
- Matrix testing across Elixir 1.15.7-1.16.0 and OTP 26.1-26.2
- Code formatting validation
- Static analysis with Credo
- Type checking with Dialyzer
- Comprehensive test suite with coverage
- Security scanning and quality checks
- Codecov integration for coverage reporting

### 🌙 nightly.yml - Comprehensive Testing
**Triggers**: Daily at 2 AM UTC, Manual dispatch
**Purpose**: Deep quality assurance and monitoring

**Features**:
- Extended build matrix testing
- Security vulnerability scanning
- Dependency audit and license checking
- Performance benchmarking
- Property-based testing
- Detailed coverage analysis
- Dependency update monitoring

### 🚀 release.yml - Automated Releases
**Triggers**: Version tags (v*.*.*), Manual dispatch
**Purpose**: Production release automation

**Features**:
- Version consistency validation
- Production artifact creation
- Multi-platform Docker images (amd64/arm64)
- GitHub release creation with artifacts
- Automated release notes generation
- Checksum verification
- Release notification system

## Container Strategy

### Dockerfile
Multi-stage build optimized for production:
- **Builder stage**: Compiles Elixir release with all dependencies
- **Runtime stage**: Minimal Alpine-based runtime with only necessary components
- **Debug stage**: Additional debugging tools for development/troubleshooting

### docker-compose.yml
Complete development environment with observability stack:
- **Arbor**: Main application with health checks
- **Prometheus**: Metrics collection and alerting
- **Jaeger**: Distributed tracing
- **Grafana**: Visualization dashboards
- **Redis**: Distributed state (optional)
- **PostgreSQL**: Persistence layer (optional)
- **Elasticsearch**: Log aggregation (optional)

## Quality Gates

### Pull Request Requirements
- ✅ All tests pass across matrix
- ✅ Code formatting compliance
- ✅ Static analysis passes (Credo)
- ✅ Type checking passes (Dialyzer)
- ✅ Security scan clean
- ✅ Coverage threshold met

### Release Requirements
- ✅ Version consistency (mix.exs ↔ git tag)
- ✅ Full test suite passes
- ✅ Documentation generation succeeds
- ✅ Production build completes
- ✅ Docker image builds successfully

## Observability Integration

Following the comprehensive observability strategy from `docs/arbor/06-infrastructure/observability.md`:

### Metrics Collection
- Prometheus scraping from `/metrics` endpoint
- BEAM VM metrics, agent lifecycle metrics, security events
- Custom business metrics for sessions and tasks

### Distributed Tracing
- OpenTelemetry integration with Jaeger
- Cross-service trace propagation
- Agent operation and capability grant tracing

### Structured Logging
- JSON-formatted logs with consistent fields
- Log aggregation via Elasticsearch
- Correlation with traces via trace_id/span_id

## Security Features

### Dependency Management
- Automated vulnerability scanning with `mix deps.audit`
- License compliance checking
- Retired package detection
- Regular dependency update monitoring

### Code Security
- Hardcoded secrets detection
- Static security analysis with Sobelow (when configured)
- Container image scanning
- Multi-stage builds to minimize attack surface

## Environment Configuration

### Development
```bash
# Local development with observability
docker-compose up -d

# Access services
# - Arbor: http://localhost:4000
# - Grafana: http://localhost:3000 (admin/admin)
# - Prometheus: http://localhost:9090
# - Jaeger: http://localhost:16686
```

### Production
```bash
# Build production image
docker build -t arbor:latest .

# Run with minimal dependencies
docker run -p 4000:4000 \
  -e NODE_NAME=arbor@prod.local \
  -e ERLANG_COOKIE=secure_production_cookie \
  arbor:latest
```

## Monitoring and Alerting

### Health Checks
- Container health check via `scripts/health_check.sh`
- HTTP endpoint monitoring
- Erlang node health verification
- Application state validation
- Memory usage monitoring

### Alert Levels
- **Critical (P1)**: Service degradation, security breaches
- **High (P2)**: Performance issues, elevated failure rates
- **Medium (P3)**: Operational issues, resource trends

## Performance Considerations

### Build Optimization
- Multi-stage Docker builds reduce final image size
- Dependency caching across CI runs
- PLT (Persistent Lookup Table) caching for Dialyzer
- Selective file copying with .dockerignore

### Runtime Optimization
- Alpine-based runtime images
- Non-root user execution
- Minimal runtime dependencies
- Health check timeout tuning

## Troubleshooting

### Common Issues

**CI Failures**:
1. Check test output for specific failures
2. Verify formatting with `mix format --check-formatted`
3. Run `mix credo --strict` locally
4. Rebuild PLT if Dialyzer fails: `mix dialyzer --plt`

**Docker Build Issues**:
1. Verify all dependencies are available
2. Check .dockerignore for excluded files
3. Ensure health check script is executable
4. Validate multi-stage build dependencies

**Coverage Issues**:
1. Check ExCoveralls configuration in `coveralls.json`
2. Verify test execution with `mix test.ci`
3. Ensure all umbrella apps are covered

## Release Process

### Automated Release
1. Ensure CHANGELOG.md is updated
2. Update version in `mix.exs`
3. Create and push version tag:
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
4. GitHub Actions automatically:
   - Validates version consistency
   - Runs full test suite
   - Builds Docker images
   - Creates GitHub release
   - Uploads artifacts

### Manual Release
Use the workflow dispatch feature in GitHub Actions to trigger releases manually with custom version numbers.

## Contributing

When contributing to the CI/CD pipeline:

1. Test changes in a fork first
2. Update documentation for new features
3. Ensure backward compatibility
4. Follow conventional commit messages
5. Update this README for significant changes

## Related Documentation

- [Architecture Overview](../docs/arbor/01-overview/architecture-overview.md)
- [Observability Strategy](../docs/arbor/06-infrastructure/observability.md)
- [Development Scripts](../scripts/README.md)
- [Quality Tools Configuration](../mix.exs)