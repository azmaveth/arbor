# Arbor Testing Strategy

> **Consensus-Driven Testing Strategy for Distributed AI Agent Orchestration**
> 
> *Developed through collaborative analysis by o3-Pro and o3 models*
> *Balances developer velocity with distributed system reliability*

## 🎯 Overview

This document defines our comprehensive testing strategy for Arbor, a distributed AI agent orchestration system built on Elixir/OTP with Horde CRDT. Our approach uses a **layered testing architecture** with strategic mocking to achieve fast feedback loops while maintaining high confidence in distributed behavior.

### Core Philosophy

**"Mock what you don't own, test what you do"**

- Mock external dependencies (databases, HTTP APIs, vector stores)
- Use in-memory stubs for distributed components in unit tests
- Test real distributed behavior at integration and system levels
- Validate steel thread (CLI → Gateway → Agent → Response) at all levels

## 📊 Testing Matrix

| **Test Scope** | **What's Real** | **Purpose** | **When** | **Duration** | **Tag** |
|---|---|---|---|---|---|
| **Unit Fast** | Pure functions, mocked adapters | Logic correctness | Every save | <30s | `:fast` |
| **Unit Horde** | In-memory CRDT stub | Concurrency edge cases | Every save | <30s | `:fast` |
| **Contract** | CLI ↔ Gateway, Gateway ↔ Session | Interface stability | Every PR | ~2 min | `:contract` |
| **Single-node** | All Elixir processes, Testcontainers | Steel thread validation | Every PR | ~8 min | `:integration` |
| **Multi-node** | 3+ Docker nodes, real partitions | Cluster consensus | Nightly/On-demand | ~15 min | `:distributed` |
| **Chaos/Property** | Fault injection + QuickCheck | Safety/liveness | Nightly/Release | ~30 min | `:chaos` |

## 🏗️ Test Architecture Layers

### Layer 1: Unit Tests (70% of test suite)

**Scope**: Individual functions, modules, and components in isolation

**Mocking Strategy**:
```elixir
# Mock external adapters
@tag :fast
test "agent spawning validates parameters" do
  # Use Mox to mock database calls
  MockRepo
  |> expect(:get_agent_spec, fn _ -> {:ok, valid_spec} end)
  
  assert {:ok, _} = AgentManager.spawn_agent(valid_params)
end

# Use in-memory Horde stub
@tag :fast  
test "registry handles concurrent registrations" do
  # Use HordeStub instead of real distributed registry
  assert :ok = HordeStub.register("agent-1", self())
end
```

**Tools**:
- `Mox` for behavior-based mocking
- Custom `HordeStub` for CRDT simulation
- `ExUnit` with property-based testing via `StreamData`

### Layer 2: Contract Tests

**Scope**: Interface boundaries between major components

**Purpose**: Ensure API compatibility and prevent silent breakage

```elixir
@tag :contract
test "CLI spawn command matches Gateway expectations" do
  # Validate that CLI generates correct HTTP requests
  command = CLI.SpawnCommand.build(:code_analyzer, %{working_dir: "/tmp"})
  
  # Verify Gateway can parse and validate the request
  assert {:ok, parsed} = Gateway.parse_spawn_request(command)
  assert Gateway.validate_spawn_request(parsed) == :ok
end
```

**Key Boundaries**:
- CLI ↔ HTTP Gateway
- Gateway ↔ Session Manager  
- Session ↔ Agent Orchestrator
- Agent ↔ Capability System

### Layer 3: Integration Tests (20% of test suite)

**Scope**: Single-node end-to-end workflows with real components

**Infrastructure**: 
- Real Elixir processes and supervision trees
- Testcontainers for external dependencies
- In-process HTTP server for Gateway testing

```elixir
@tag :integration
test "complete agent lifecycle steel thread" do
  # Start real Gateway, Session Manager, and Agent infrastructure
  {:ok, gateway_pid} = Gateway.start_link([])
  {:ok, session_id} = Gateway.create_session(user_id: "test-user")
  
  # Execute complete steel thread
  assert {:ok, agent_id} = Gateway.spawn_agent(session_id, :code_analyzer, %{})
  assert {:ok, result} = Gateway.execute_command(session_id, agent_id, :analyze, ["./lib"])
  assert {:ok, _} = Gateway.stop_agent(session_id, agent_id)
end
```

### Layer 4: Distributed Tests (10% of test suite)

**Scope**: Multi-node cluster behavior, consensus, and fault tolerance

**Infrastructure**: 
- Docker Compose with 3+ nodes
- Real network partitions and node failures
- Kubernetes support for advanced scenarios

```elixir
@tag :distributed
test "agent redistribution after node failure" do
  # Start 3-node cluster
  nodes = start_cluster_nodes(3)
  
  # Deploy agents across cluster
  agents = deploy_test_agents(nodes, count: 10)
  
  # Kill one node
  kill_node(Enum.at(nodes, 1))
  
  # Verify agents redistribute and remain functional
  wait_for_redistribution()
  assert all_agents_responsive?(agents)
end
```

## 🚀 Development Workflow

### Local Development

```bash
# Fast feedback loop (runs on file save)
mix test --only fast                    # <2 min

# Pre-commit validation  
mix test --only fast,contract           # ~3 min
mix format --check-formatted
mix credo --strict
mix dialyzer
```

### CI/CD Pipeline

#### Pull Request Pipeline (~10 min total)
```bash
# 1. Code quality checks
mix format --check-formatted
mix credo --strict  
mix dialyzer

# 2. Fast test suite
mix test --only fast,contract           # ~3 min

# 3. Integration tests
mix test --only integration             # ~8 min

# 4. Contract validation
mix test.contracts                      # ~2 min
```

#### Nightly Pipeline (~45 min total)
```bash
# 1. Full test suite
mix test                                # ~15 min

# 2. Distributed system tests
mix test.distributed                    # ~15 min

# 3. Chaos engineering
mix test.chaos                          # ~15 min

# 4. Performance benchmarks
mix run scripts/benchmark.sh            # ~10 min
```

#### Release Pipeline
```bash
# All nightly tests +
mix test.performance                    # Load testing
mix test.security                       # Security validation  
mix test.compatibility                  # Backward compatibility
```

## 🐳 Infrastructure Setup

### Docker Compose for Multi-Node Testing

```yaml
# docker-compose.test.yml
version: '3.8'
services:
  node1:
    image: arbor:test
    environment:
      - NODE_NAME=node1@cluster
      - CLUSTER_NODES=node1@cluster,node2@cluster,node3@cluster
    networks:
      - arbor-test

  node2:
    image: arbor:test  
    environment:
      - NODE_NAME=node2@cluster
      - CLUSTER_NODES=node1@cluster,node2@cluster,node3@cluster
    networks:
      - arbor-test

  node3:
    image: arbor:test
    environment:
      - NODE_NAME=node3@cluster  
      - CLUSTER_NODES=node1@cluster,node2@cluster,node3@cluster
    networks:
      - arbor-test

networks:
  arbor-test:
    driver: bridge
```

### Kubernetes for Advanced Testing

```yaml
# k8s/test-cluster.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: arbor-test-config
data:
  cluster.nodes: "arbor-0.arbor-test,arbor-1.arbor-test,arbor-2.arbor-test"
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: arbor-test
spec:
  serviceName: arbor-test
  replicas: 3
  selector:
    matchLabels:
      app: arbor-test
  template:
    metadata:
      labels:
        app: arbor-test
    spec:
      containers:
      - name: arbor
        image: arbor:test
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: CLUSTER_NODES
          valueFrom:
            configMapKeyRef:
              name: arbor-test-config
              key: cluster.nodes
```

## 🧪 Test Implementation Guide

### 1. Setting Up Test Tags

```elixir
# test/test_helper.exs
ExUnit.start()

# Exclude distributed tests by default
ExUnit.configure(exclude: [:distributed, :chaos])

# Include only fast tests for watch mode
if System.get_env("TEST_WATCH") do
  ExUnit.configure(include: [:fast], exclude: [:integration, :distributed, :chaos])
end
```

### 2. Creating Mock Infrastructure

```elixir
# test/support/horde_stub.ex
defmodule Arbor.Test.HordeStub do
  @moduledoc """
  In-memory CRDT stub for fast unit testing.
  Simulates Horde behavior without distributed overhead.
  """
  
  use Agent
  
  def start_link(_opts) do
    Agent.start_link(fn -> %{registry: %{}, supervisor: %{}} end, name: __MODULE__)
  end
  
  def register(key, pid) do
    Agent.update(__MODULE__, fn state ->
      put_in(state, [:registry, key], pid)
    end)
  end
  
  def lookup(key) do
    Agent.get(__MODULE__, fn state ->
      Map.get(state.registry, key)
    end)
  end
end
```

### 3. Property-Based Testing Examples

```elixir
# test/property/agent_consistency_test.exs
defmodule Arbor.Property.AgentConsistencyTest do
  use ExUnit.Case
  use ExUnitProperties
  
  @tag :property
  property "agent operations maintain CRDT consistency" do
    check all operations <- list_of(agent_operation_generator(), min_length: 1) do
      {:ok, cluster} = start_test_cluster(3)
      
      # Apply operations concurrently across nodes
      results = apply_operations_concurrently(cluster, operations)
      
      # Verify eventual consistency
      wait_for_convergence(cluster)
      assert consistent_state?(cluster)
      
      cleanup_cluster(cluster)
    end
  end
  
  defp agent_operation_generator do
    one_of([
      {:spawn_agent, agent_spec_generator()},
      {:stop_agent, agent_id_generator()},
      {:update_agent, agent_id_generator(), metadata_generator()}
    ])
  end
end
```

### 4. Chaos Testing Framework

```elixir
# test/chaos/network_partition_test.exs
defmodule Arbor.Chaos.NetworkPartitionTest do
  use ExUnit.Case
  
  @tag :chaos
  test "system recovers from network partition" do
    # Start 5-node cluster
    {:ok, cluster} = start_cluster_nodes(5)
    
    # Deploy critical agents
    agents = deploy_critical_agents(cluster)
    
    # Create partition: [node1, node2] vs [node3, node4, node5]
    partition = create_network_partition(cluster, [1, 2], [3, 4, 5])
    
    # Wait for partition detection
    :timer.sleep(5000)
    
    # Verify both sides continue operating
    assert cluster_functional?(partition.minority)
    assert cluster_functional?(partition.majority)
    
    # Heal partition
    heal_network_partition(partition)
    
    # Verify convergence and consistency
    wait_for_convergence(cluster, timeout: 30_000)
    assert consistent_state?(cluster)
    assert all_agents_functional?(agents)
  end
end
```

## 📝 Test Commands Reference

### Basic Test Commands

```bash
# Fast development cycle
mix test --only fast

# Contract validation
mix test --only contract

# Integration testing
mix test --only integration

# Full single-node suite
mix test --exclude distributed,chaos

# Distributed system testing  
ARBOR_DISTRIBUTED_TEST=true mix test --only distributed

# Chaos engineering
mix test --only chaos

# Property-based testing
mix test --only property
```

### Advanced Test Commands

```bash
# Performance testing
mix test.perf

# Security testing
mix test.security

# Load testing
mix test.load --duration=300 --concurrency=100

# Compatibility testing
mix test.compat --version=1.0.0

# Generate test reports
mix test.report --format=html --output=test_results/
```

### Docker-based Testing

```bash
# Start test cluster
docker-compose -f docker-compose.test.yml up -d

# Run distributed tests against cluster
mix test.distributed --cluster=docker

# Chaos testing with Docker
mix test.chaos --cluster=docker --scenarios=network_partition,node_failure

# Cleanup
docker-compose -f docker-compose.test.yml down -v
```

### Kubernetes-based Testing

```bash
# Deploy test cluster
kubectl apply -f k8s/test-cluster.yaml

# Run distributed tests
mix test.distributed --cluster=k8s --namespace=arbor-test

# Advanced chaos scenarios
mix test.chaos --cluster=k8s --chaos-monkey=enabled

# Cleanup
kubectl delete -f k8s/test-cluster.yaml
```

## 📈 Success Metrics

### Performance Targets

- **Unit tests**: <2 minutes for full suite
- **Integration tests**: <10 minutes for full suite  
- **Distributed tests**: <30 minutes for full suite
- **Chaos tests**: <45 minutes for full suite

### Quality Gates

- **Code coverage**: >80% for business logic
- **Contract coverage**: 100% for public interfaces
- **Mutation testing**: >70% for critical paths
- **Property test coverage**: >90% for distributed operations

### Reliability Metrics

- **Test flakiness**: <1% failure rate on clean runs
- **Distributed consistency**: 100% convergence in tests
- **Fault tolerance**: System recovers from 50% node failures
- **Performance regression**: <5% degradation between releases

## 🛠️ Implementation Roadmap

### Phase 1: Foundation (Week 1-2)
- [x] Tag existing tests with appropriate categories
- [x] Set up test command structure
- [ ] Create mock infrastructure (HordeStub, adapters)
- [ ] Implement basic contract testing framework

### Phase 2: Integration (Week 3-4)
- [ ] Set up Testcontainers for external dependencies
- [ ] Create single-node integration test suite
- [ ] Implement steel thread validation tests
- [ ] Add contract snapshot testing

### Phase 3: Distribution (Week 5-6)  
- [ ] Set up Docker Compose test cluster
- [ ] Implement multi-node test infrastructure
- [ ] Create distributed consensus tests
- [ ] Add fault tolerance validation

### Phase 4: Advanced (Week 7-8)
- [ ] Implement property-based testing framework
- [ ] Create chaos engineering test suite
- [ ] Set up performance benchmarking
- [ ] Add security testing framework

### Phase 5: Optimization (Week 9-10)
- [ ] Optimize test performance and reliability
- [ ] Create comprehensive CI/CD integration
- [ ] Add monitoring and alerting for test metrics
- [ ] Document team training materials

## 🎓 Team Training & Best Practices

### Property-Based Testing Guidelines
- Focus on invariants that should always hold
- Use generators that produce realistic test data
- Start with simple properties, increase complexity gradually
- Document property meanings for team understanding

### Chaos Engineering Principles
- Start with hypothesis about system behavior
- Minimize blast radius during experiments
- Automate chaos scenarios for consistency
- Always have rollback/recovery procedures

### Mock Strategy Guidelines
- Mock at architectural boundaries, not implementation details
- Keep mocks simple and focused on behavior
- Verify mock interactions in addition to return values
- Regularly validate mocks against real implementations

## 📚 Additional Resources

### Tools & Libraries
- **Mox**: Behavior-based mocking
- **ExVCR**: HTTP request/response recording
- **Testcontainers**: Containerized test dependencies
- **StreamData**: Property-based testing
- **Benchee**: Performance benchmarking
- **Wallaby**: Browser-based testing (if needed)

### External References
- [Property-Based Testing with PropEr, Erlang, and Elixir](https://propertesting.com/)
- [Chaos Engineering Principles](https://principlesofchaos.org/)
- [Testing Microservices with Contract Testing](https://martinfowler.com/articles/microservice-testing/)
- [The Practical Test Pyramid](https://martinfowler.com/articles/practical-test-pyramid.html)

---

## 📋 Quick Reference

### Test Tags
- `:fast` - Unit tests (<30s)
- `:contract` - Interface boundary tests
- `:integration` - Single-node integration tests  
- `:distributed` - Multi-node cluster tests
- `:chaos` - Fault injection tests
- `:property` - Property-based tests
- `:performance` - Performance benchmarks
- `:security` - Security validation tests

### Environment Variables
- `ARBOR_DISTRIBUTED_TEST=true` - Enable distributed testing
- `TEST_WATCH=true` - Run only fast tests in watch mode
- `CHAOS_MONKEY=enabled` - Enable chaos engineering
- `TEST_CLUSTER=docker|k8s` - Specify cluster type for distributed tests

### Quick Commands
```bash
# Daily development
mix test --only fast

# Pre-PR check  
mix test --exclude distributed,chaos

# Full validation
mix test.all

# Distributed testing
mix test.distributed
```

This testing strategy provides a robust foundation for maintaining quality while enabling rapid development of our distributed AI agent orchestration system.