# Arbor Security Application Specification

## Overview

The `arbor_security` application implements the capability-based security model for Arbor. It provides fine-grained, delegatable permissions for agents accessing resources through a central SecurityKernel.

## Application Structure

```
apps/arbor_security/
├── lib/
│   └── arbor/
│       └── security/
│           ├── application.ex       # OTP Application
│           ├── security.ex          # Public API
│           ├── kernel.ex            # SecurityKernel GenServer
│           ├── audit_logger.ex      # Structured security logging
│           ├── validators/
│           │   ├── filesystem.ex    # Path validation
│           │   ├── api.ex           # URL/method validation
│           │   └── database.ex      # Query validation
│           └── policies/
│               ├── default.ex       # Default security policies
│               └── policy.ex        # Policy behaviour
├── mix.exs
├── README.md
└── test/
```

## Dependencies

- [`arbor_contracts`](../../03-contracts/core-contracts.md) - Core data structures and contracts

```elixir
# mix.exs
defp deps do
  [
    {:arbor_contracts, in_umbrella: true},
    {:telemetry, "~> 1.0"}
  ]
end
```

## Public API Module

```elixir
defmodule Arbor.Security do
  @moduledoc """
  Public API for capability-based security operations.
  All functions delegate to the SecurityKernel GenServer.
  """

  alias Arbor.Security.{Kernel, Capability}
  alias Arbor.Types

  @doc """
  Request a capability for resource access.
  
  ## Examples
      
      {:ok, cap} = Arbor.Security.request(:fs, :read, "/path/to/file")
      {:ok, cap} = Arbor.Security.request(:api, :post, "https://api.github.com/repos")
      
  """
  @spec request(
    resource_type :: Types.resource_type(),
    operation :: Types.operation(),
    resource :: binary(),
    opts :: keyword()
  ) :: {:ok, Capability.t()} | Types.error()
  def request(resource_type, operation, resource, opts \\ []) do
    principal_id = self() |> inspect()
    resource_uri = build_resource_uri(resource_type, operation, resource)
    
    Kernel.request_capability(principal_id, resource_uri, opts)
  end

  @doc """
  Delegate a capability to another agent with optional constraints.
  """
  @spec delegate(
    capability :: Capability.t(),
    to :: pid() | Types.agent_id(),
    constraints :: map()
  ) :: {:ok, Capability.t()} | Types.error()
  def delegate(capability, to, constraints \\ %{}) do
    recipient_id = normalize_principal(to)
    Kernel.delegate_capability(capability, recipient_id, constraints)
  end

  @doc """
  Validate a capability for a specific resource operation.
  Used internally by resource modules.
  """
  @spec validate(
    capability :: Capability.t(),
    for_resource :: tuple()
  ) :: :ok | Types.error()
  def validate(capability, for_resource: {type, op, resource}) do
    resource_uri = build_resource_uri(type, op, resource)
    Kernel.validate_capability(capability, resource_uri)
  end

  @doc """
  Revoke a capability and all its delegated children.
  """
  @spec revoke(capability :: Capability.t() | Types.capability_id()) :: :ok
  def revoke(%Capability{id: id}), do: revoke(id)
  def revoke(capability_id) when is_binary(capability_id) do
    Kernel.revoke_capability(capability_id)
  end

  @doc """
  List all capabilities held by the calling process.
  """
  @spec list_my_capabilities() :: {:ok, [Capability.t()]}
  def list_my_capabilities do
    principal_id = self() |> inspect()
    Kernel.list_capabilities_for(principal_id)
  end

  # Private helpers
  
  defp build_resource_uri(type, operation, resource) do
    "arbor://#{type}/#{operation}/#{resource}"
  end
  
  defp normalize_principal(pid) when is_pid(pid), do: inspect(pid)
  defp normalize_principal(id) when is_binary(id), do: id
end
```

## SecurityKernel GenServer

```elixir
defmodule Arbor.Security.Kernel do
  @moduledoc """
  Central authority for capability management.
  Runs as a singleton process in the cluster.
  """
  
  use GenServer
  require Logger
  
  alias Arbor.Security.{Capability, AuditLogger}
  alias Arbor.Security.Validators
  
  # Client API
  
  def start_link(opts) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end
  
  def request_capability(principal_id, resource_uri, opts) do
    GenServer.call(__MODULE__, {:request, principal_id, resource_uri, opts})
  end
  
  def validate_capability(capability, resource_uri) do
    GenServer.call(__MODULE__, {:validate, capability, resource_uri})
  end
  
  def delegate_capability(capability, recipient_id, constraints) do
    GenServer.call(__MODULE__, {:delegate, capability, recipient_id, constraints})
  end
  
  def revoke_capability(capability_id) do
    GenServer.cast(__MODULE__, {:revoke, capability_id})
  end
  
  # Server callbacks
  
  defmodule State do
    defstruct [
      :capabilities,         # %{capability_id => Capability}
      :agent_capabilities,   # %{agent_id => MapSet.t(capability_id)}
      :delegation_tree,      # %{parent_id => MapSet.t(child_id)}
      :revoked,             # %{capability_id => revoked_at}
      :monitors,            # %{monitor_ref => agent_id}
      :validator_cache      # %{resource_type => validator_module}
    ]
  end
  
  @impl true
  def init(_opts) do
    state = %State{
      capabilities: %{},
      agent_capabilities: %{},
      delegation_tree: %{},
      revoked: %{},
      monitors: %{},
      validator_cache: build_validator_cache()
    }
    
    # TODO: Load persisted state
    
    Logger.info("SecurityKernel started", event: :security_kernel_started)
    {:ok, state}
  end
  
  @impl true
  def handle_call({:request, principal_id, resource_uri, opts}, _from, state) do
    with {:ok, _type, _op, _resource} <- parse_resource_uri(resource_uri),
         :ok <- check_request_allowed?(principal_id, resource_uri, state),
         {:ok, capability} <- create_capability(principal_id, resource_uri, opts) do
      
      new_state = state
        |> store_capability(capability)
        |> monitor_agent(principal_id)
      
      AuditLogger.log(:capability_granted, capability)
      
      {:reply, {:ok, capability}, new_state}
    else
      {:error, reason} = error ->
        AuditLogger.log(:capability_denied, %{
          principal_id: principal_id,
          resource_uri: resource_uri,
          reason: reason
        })
        {:reply, error, state}
    end
  end
  
  @impl true
  def handle_call({:validate, capability, resource_uri}, _from, state) do
    result = perform_validation(capability, resource_uri, state)
    
    AuditLogger.log(:capability_validated, %{
      capability_id: capability.id,
      resource_uri: resource_uri,
      result: result
    })
    
    {:reply, result, state}
  end
  
  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}
        
      agent_id ->
        Logger.warning("Agent terminated, revoking capabilities",
          agent_id: agent_id,
          reason: reason
        )
        
        new_state = cleanup_agent_capabilities(agent_id, state)
        {:noreply, new_state}
    end
  end
  
  # Private implementation
  
  defp create_capability(principal_id, resource_uri, opts) do
    capability = %Capability{
      id: generate_capability_id(),
      resource_uri: resource_uri,
      principal_id: principal_id,
      granted_at: DateTime.utc_now(),
      expires_at: calculate_expiry(opts),
      delegation_depth: opts[:delegation_depth] || 3,
      constraints: opts[:constraints] || %{},
      metadata: opts[:metadata] || %{}
    }
    
    {:ok, capability}
  end
  
  defp perform_validation(capability, requested_uri, state) do
    with :ok <- check_not_revoked(capability, state),
         :ok <- check_not_expired(capability),
         :ok <- check_principal_match(capability),
         :ok <- check_resource_match(capability, requested_uri, state) do
      :ok
    end
  end
  
  defp check_resource_match(capability, requested_uri, state) do
    with {:ok, cap_type, cap_op, cap_resource} <- parse_resource_uri(capability.resource_uri),
         {:ok, req_type, req_op, req_resource} <- parse_resource_uri(requested_uri),
         true <- cap_type == req_type,
         true <- cap_op == req_op do
      
      validator = get_validator(cap_type, state)
      validator.validate_resource(cap_resource, req_resource, capability.constraints)
    else
      _ -> {:error, :resource_mismatch}
    end
  end
  
  defp parse_resource_uri("arbor://" <> rest) do
    case String.split(rest, "/", parts: 3) do
      [type, operation, resource] ->
        {:ok, String.to_atom(type), String.to_atom(operation), resource}
      _ ->
        {:error, :invalid_uri}
    end
  end
  
  defp generate_capability_id do
    "cap_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end
end
```

## Resource Validators

```elixir
defmodule Arbor.Security.Validators.Filesystem do
  @moduledoc """
  Validates filesystem resource access.
  """
  
  @behaviour Arbor.Security.Validator
  
  @impl true
  def validate_resource(granted_path, requested_path, constraints) do
    # Normalize paths to prevent traversal attacks
    granted = Path.expand(granted_path)
    requested = Path.expand(requested_path)
    
    cond do
      # Exact match
      granted == requested ->
        :ok
        
      # Wildcard match
      String.ends_with?(granted, "**") ->
        prefix = String.trim_trailing(granted, "**")
        if String.starts_with?(requested, prefix) do
          check_constraints(requested, constraints)
        else
          {:error, :path_not_allowed}
        end
        
      # Directory match
      String.ends_with?(granted, "/") and String.starts_with?(requested, granted) ->
        check_constraints(requested, constraints)
        
      true ->
        {:error, :path_not_allowed}
    end
  end
  
  defp check_constraints(path, constraints) do
    with :ok <- check_denied_paths(path, constraints[:denied_paths] || []),
         :ok <- check_file_size(path, constraints[:max_file_size]) do
      :ok
    end
  end
  
  defp check_denied_paths(path, denied_patterns) do
    if Enum.any?(denied_patterns, &path_matches?(path, &1)) do
      {:error, :path_denied_by_constraint}
    else
      :ok
    end
  end
  
  defp path_matches?(path, pattern) do
    regex = pattern
      |> String.replace("**", ".*")
      |> String.replace("*", "[^/]*")
      |> Regex.compile!()
      
    Regex.match?(regex, path)
  end
end
```

## Audit Logger

```elixir
defmodule Arbor.Security.AuditLogger do
  @moduledoc """
  Structured logging for security events.
  """
  
  require Logger
  
  @events [
    :capability_requested,
    :capability_granted,
    :capability_denied,
    :capability_delegated,
    :capability_revoked,
    :capability_validated,
    :security_violation
  ]
  
  def log(event, data) when event in @events do
    metadata = build_metadata(event, data)
    
    Logger.info("Security event: #{event}",
      event_type: event,
      trace_id: generate_trace_id(),
      timestamp: DateTime.utc_now(),
      data: data,
      metadata: metadata
    )
    
    :telemetry.execute(
      [:arbor, :security, event],
      %{count: 1},
      metadata
    )
  end
  
  defp build_metadata(:capability_granted, %Capability{} = cap) do
    %{
      capability_id: cap.id,
      resource_uri: cap.resource_uri,
      principal_id: cap.principal_id,
      expires_at: cap.expires_at,
      delegation_depth: cap.delegation_depth
    }
  end
  
  defp build_metadata(event, data) when is_map(data) do
    data
  end
  
  defp generate_trace_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
```

## Implementation Checklist

### Phase 1: Core Implementation
- [ ] Create application structure and mix.exs
- [ ] Implement Arbor.Security public API module
- [ ] Implement SecurityKernel GenServer
  - [ ] State management
  - [ ] Capability creation and storage
  - [ ] Process monitoring
  - [ ] Basic validation logic
- [ ] Implement Filesystem validator
- [ ] Implement AuditLogger
- [ ] Add telemetry events
- [ ] Write comprehensive tests
  - [ ] Unit tests for validators
  - [ ] Integration tests for capability lifecycle
  - [ ] Property-based tests for constraint logic

### Phase 2: Advanced Features
- [ ] Add API and Database validators
- [ ] Implement persistence integration
- [ ] Add policy engine for dynamic rules
- [ ] Implement capability signing (for distributed validation)
- [ ] Add rate limiting and DoS protection
- [ ] Create management CLI tools

### Phase 3: Production Hardening
- [ ] Performance optimization
- [ ] Distributed state management with Horde
- [ ] Comprehensive security audit
- [ ] Load testing and benchmarking
- [ ] Operational runbooks

## Testing Strategy

```elixir
# Example test
defmodule Arbor.SecurityTest do
  use ExUnit.Case
  
  setup do
    # Start isolated SecurityKernel for testing
    {:ok, kernel} = Arbor.Security.Kernel.start_link(name: nil)
    {:ok, kernel: kernel}
  end
  
  describe "capability lifecycle" do
    test "request, validate, and revoke" do
      # Request capability
      {:ok, cap} = Arbor.Security.request(:fs, :read, "/tmp/test.txt")
      assert %Capability{} = cap
      
      # Validate for exact match
      assert :ok = Arbor.Security.validate(cap, for_resource: {:fs, :read, "/tmp/test.txt"})
      
      # Validate for non-match fails
      assert {:error, :path_not_allowed} = 
        Arbor.Security.validate(cap, for_resource: {:fs, :read, "/tmp/other.txt"})
      
      # Revoke
      assert :ok = Arbor.Security.revoke(cap)
      
      # Validation after revoke fails
      assert {:error, :capability_revoked} = 
        Arbor.Security.validate(cap, for_resource: {:fs, :read, "/tmp/test.txt"})
    end
  end
end
```