# Distributed System Timing Configuration

Arbor provides configurable timing parameters for distributed system operations. These settings allow you to tune the system for different environments and network conditions.

## Configuration Parameters

### Agent Retry Configuration (`agent_retry`)

Controls how agents retry registration when encountering race conditions or CRDT synchronization delays.

```elixir
config :arbor_core,
  agent_retry: [
    retries: 3,          # Number of retry attempts
    initial_delay: 250   # Initial delay in milliseconds (doubles with each retry)
  ]
```

**Parameters:**
- `retries`: Number of retry attempts before giving up (0-10 recommended)
- `initial_delay`: Initial delay in milliseconds, uses exponential backoff

### Horde CRDT Timing Configuration (`horde_timing`)

Controls the synchronization interval for Horde's CRDT-based distributed state.

```elixir
config :arbor_core,
  horde_timing: [
    sync_interval: 100   # CRDT sync interval in milliseconds
  ]
```

**Parameters:**
- `sync_interval`: Time between CRDT synchronization attempts in milliseconds
  - Minimum recommended: 100ms
  - Lower values increase network traffic and CPU usage
  - Higher values may increase eventual consistency delays

## Environment-Specific Recommendations

### Development (`config/dev.exs`)
- **Faster feedback**: Lower delays for quick iteration
- **Local network**: Minimal latency considerations

```elixir
config :arbor_core,
  agent_retry: [retries: 3, initial_delay: 100],
  horde_timing: [sync_interval: 100]
```

### Test (`config/test.exs`)
- **Reliability over speed**: More retries to handle test cluster latency
- **CRDT convergence**: Allow time for distributed state synchronization

```elixir
config :arbor_core,
  agent_retry: [retries: 5, initial_delay: 100],
  horde_timing: [sync_interval: 100]
```

### Production (`config/prod.exs`)
- **Network resilience**: Higher retry counts for variable network conditions
- **Stability**: Conservative sync intervals for predictable behavior

```elixir
config :arbor_core,
  agent_retry: [retries: 5, initial_delay: 500],
  horde_timing: [sync_interval: 200]
```

## Tuning Guidelines

### When to Increase `retries`:
- Unreliable network connections
- High node count clusters
- Heavy concurrent load
- Frequent agent creation/destruction

### When to Increase `initial_delay`:
- High network latency
- Slow node startup times
- Resource-constrained environments
- Want to reduce retry traffic

### When to Increase `sync_interval`:
- Large cluster sizes (>10 nodes)
- Limited network bandwidth
- CPU resource constraints
- Prefer consistency over speed

### When to Decrease `sync_interval`:
- Small cluster sizes (<5 nodes)
- Fast local networks
- Need faster state convergence
- Have sufficient CPU/network resources

## Debugging Distribution Issues

### Common Symptoms and Solutions

**"max retries reached" errors:**
- Increase `retries` count
- Increase `initial_delay` to allow more time between attempts
- Check network connectivity between nodes

**"name taken" race conditions:**
- Ensure `sync_interval` is at least 100ms
- Increase `retries` to allow CRDT state to converge
- Verify nodes are properly connected

**Performance warnings about sync_interval:**
- Increase `sync_interval` to at least 100ms
- Monitor CPU usage and network traffic
- Consider cluster size and hardware capacity

## Monitoring

Watch these metrics to tune your configuration:
- Agent registration failure rates
- CRDT sync latency
- Network traffic between nodes
- CPU usage on distributed operations
- Time to eventual consistency

## Default Values

The system provides sensible defaults that work for most use cases:

```elixir
# Default configuration (from config/config.exs)
config :arbor_core,
  agent_retry: [retries: 3, initial_delay: 250],
  horde_timing: [sync_interval: 100]
```

These defaults are optimized for production stability while maintaining reasonable performance.