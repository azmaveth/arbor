# Section 08: Reference

This section provides technical reference documentation for Arbor.

## Documents in this Section

### [API Reference](./api-reference.md) *(Coming Soon)*
Complete API documentation:
- Public module APIs
- Behavior callbacks
- Contract specifications
- Usage examples

### [Configuration Reference](./configuration.md) *(Coming Soon)*
All configuration options:
- Application configuration
- Runtime configuration
- Environment variables
- Feature flags

### [Glossary](./glossary.md) *(Coming Soon)*
Definitions of key terms and concepts used throughout Arbor.

## Quick Reference

### Core Behaviours

```elixir
# Agent Behaviour
@callback init(args :: any()) :: {:ok, state()} | {:stop, reason()}
@callback handle_message(message :: Envelope.t(), state()) :: 
  {:noreply, state()} | {:reply, reply :: any(), state()} | {:stop, reason(), state()}
@callback handle_capability(capability :: Capability.t(), state()) ::
  {:ok, state()} | {:error, reason()}
@callback terminate(reason :: reason(), state()) :: :ok

# SecurityProvider Behaviour
@callback check_permission(agent_id(), capability_request()) :: 
  {:ok, capability()} | {:error, reason()}
@callback grant_capability(agent_id(), capability()) :: 
  {:ok, capability()} | {:error, reason()}
@callback revoke_capability(capability_id()) :: 
  :ok | {:error, reason()}

# PersistenceProvider Behaviour
@callback save_snapshot(key(), state()) :: :ok | {:error, reason()}
@callback load_snapshot(key()) :: {:ok, state()} | {:error, reason()}
@callback append_event(stream_id(), event()) :: :ok | {:error, reason()}
@callback replay_events(stream_id(), from_sequence()) :: {:ok, [event()]} | {:error, reason()}
```

### Common Patterns

#### Spawning an Agent
```elixir
{:ok, agent_id} = Arbor.Core.spawn_agent(:my_agent_type, %{
  config: "value",
  capabilities: [:read_files, :write_logs]
})
```

#### Sending Messages to Agents
```elixir
{:ok, response} = Arbor.Core.send_message(agent_id, %{
  type: :command,
  payload: %{action: "process_data", data: [1, 2, 3]}
})
```

#### Granting Capabilities
```elixir
{:ok, capability} = Arbor.Security.grant_capability(agent_id, %{
  resource_uri: "file:///path/to/resource",
  operation: :read,
  constraints: %{max_size: 1024 * 1024}
})
```

### Configuration Examples

```elixir
# config/config.exs
config :arbor_core,
  registry: Arbor.Core.Registry,
  supervisor: Arbor.Core.Supervisor,
  gateway_timeout: 30_000

config :arbor_security,
  provider: Arbor.Security.DefaultProvider,
  audit_log: true,
  capability_ttl: 3600

config :arbor_persistence,
  adapter: Arbor.Persistence.PostgreSQL,
  pool_size: 10,
  snapshot_interval: 300_000
```

### Error Codes

| Code | Description | Recovery Action |
|------|-------------|-----------------|
| `:agent_not_found` | Agent ID doesn't exist | Check agent spawned successfully |
| `:capability_denied` | Permission check failed | Review capability requirements |
| `:invalid_message` | Message validation failed | Check message contract |
| `:timeout` | Operation timed out | Retry with backoff |
| `:node_down` | Target node unreachable | Wait for cluster healing |

### Telemetry Events

All telemetry events follow the pattern: `[:arbor, :component, :action, :stage]`

Examples:
- `[:arbor, :agent, :spawn, :start]`
- `[:arbor, :agent, :spawn, :stop]`
- `[:arbor, :capability, :grant, :start]`
- `[:arbor, :capability, :grant, :stop]`

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ARBOR_NODE_NAME` | Erlang node name | `arbor@localhost` |
| `ARBOR_COOKIE` | Erlang distribution cookie | Random |
| `ARBOR_LOG_LEVEL` | Logging level | `info` |
| `ARBOR_METRICS_PORT` | Prometheus metrics port | `9568` |

## Next Steps

- Return to [Arbor Index](../README.md)
- Explore [Components](../04-components/README.md)
- Read [Implementation Guides](../07-implementation/README.md)