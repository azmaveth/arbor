# Arbor Contracts Specification

## Related Documentation

- [Architecture Overview](../01-overview/architecture-overview.md)
- [BEAM Philosophy](../02-philosophy/beam-philosophy.md)
- [Schema-Driven Design](./schema-driven-design.md)
- [Umbrella Structure](../01-overview/umbrella-structure.md)

## Overview

The `arbor_contracts` application defines all shared data structures, types, and contracts used throughout the Arbor distributed agent orchestration system. It serves as the single source of truth for the system's fundamental language, providing compile-time type safety, runtime validation, and clear interface boundaries.

## Design Principles

1. **Single Source of Truth**: All shared contracts are defined in one place
2. **Compile-Time Safety**: TypedStruct for catching errors early
3. **Runtime Validation**: Ecto changesets and Norm specs for boundary validation
4. **Zero Dependencies**: This application has NO dependencies on other umbrella apps
5. **Backwards Compatibility**: Once published, changes require careful versioning

## Application Structure

```
apps/arbor_contracts/
├── lib/
│   └── arbor/
│       └── contracts/
│           ├── core/              # Core business entities
│           │   ├── agent.ex
│           │   ├── capability.ex
│           │   ├── message.ex
│           │   └── session.ex
│           ├── events/            # Event sourcing events
│           │   ├── agent_events.ex
│           │   ├── session_events.ex
│           │   └── security_events.ex
│           ├── specs/             # Runtime contract specifications
│           │   ├── core_specs.ex
│           │   ├── event_specs.ex
│           │   └── api_specs.ex
│           ├── protocols/         # Serialization protocols
│           │   ├── serializable.ex
│           │   └── validatable.ex
│           └── types.ex          # Common types and guards
├── mix.exs
├── test/
└── README.md
```

## Core Behaviours

### Arbor.Agent

```elixir
defmodule Arbor.Agent do
  @moduledoc """
  Defines the contract for all agents in the system.
  """

  @type id :: binary()
  @type state :: map()
  @type reason :: atom() | binary() | tuple()

  @doc "Initialize the agent with given arguments"
  @callback init(args :: any()) :: 
    {:ok, state()} | 
    {:stop, reason()}

  @doc "Handle incoming messages"
  @callback handle_message(
    message :: Arbor.Messaging.Envelope.t(), 
    state :: state()
  ) :: 
    {:noreply, state()} | 
    {:reply, reply :: any(), state()} |
    {:stop, reason(), state()}

  @doc "Handle capability grants"
  @callback handle_capability(
    capability :: Arbor.Security.Capability.t(),
    state :: state()
  ) ::
    {:ok, state()} |
    {:error, reason()}

  @doc "Clean up on termination"
  @callback terminate(reason :: reason(), state :: state()) :: :ok

  @doc "Export state for persistence"
  @callback export_state(state :: state()) :: map()

  @doc "Import state from persistence"
  @callback import_state(persisted :: map()) :: {:ok, state()} | {:error, reason()}
end
```

### Arbor.Tool

```elixir
defmodule Arbor.Tool do
  @moduledoc """
  Defines the contract for tools that agents can execute.
  """

  @type name :: binary()
  @type args :: map()
  @type result :: {:ok, any()} | {:error, any()}

  @doc "Get tool metadata"
  @callback info() :: %{
    name: name(),
    description: binary(),
    parameters: map(),
    required_capabilities: [Arbor.Types.resource_uri()]
  }

  @doc "Execute the tool with given arguments"
  @callback execute(
    args :: args(),
    context :: map()
  ) :: result()

  @doc "Validate arguments before execution"
  @callback validate_args(args :: args()) :: :ok | {:error, reason :: any()}
end
```

### Arbor.Client

```elixir
defmodule Arbor.Client do
  @moduledoc """
  Defines the contract for system clients (CLI, Web, etc).
  """

  @type connection_info :: map()

  @doc "Handle connection to the system"
  @callback connect(connection_info()) :: 
    {:ok, session_id :: binary()} | 
    {:error, reason :: any()}

  @doc "Handle incoming events from the system"
  @callback handle_event(
    event :: any(),
    state :: any()
  ) :: {:ok, state :: any()}

  @doc "Handle disconnection"
  @callback disconnect(reason :: any()) :: :ok
end
```

### Arbor.Registry

```elixir
defmodule Arbor.Registry do
  @moduledoc """
  Defines the contract for agent/service discovery.
  """

  @type name :: any()
  @type metadata :: map()

  @callback register(name(), pid(), metadata()) :: 
    {:ok, reference :: any()} | 
    {:error, reason :: any()}

  @callback unregister(name()) :: 
    :ok | 
    {:error, reason :: any()}

  @callback lookup(name()) :: 
    {:ok, {pid(), metadata()}} | 
    :error

  @callback whereis(name()) :: 
    {:ok, pid()} | 
    :not_found

  @callback list_by_type(type :: atom()) :: 
    [{name(), pid(), metadata()}]
end
```

### Arbor.Persistence.Store

```elixir
defmodule Arbor.Persistence.Store do
  @moduledoc """
  Defines the contract for persistence backends.
  """

  @type key :: binary()
  @type value :: any()
  @type opts :: keyword()

  @callback init(opts()) :: {:ok, state :: any()} | {:error, reason :: any()}

  @callback put(key(), value(), state :: any()) :: 
    {:ok, state :: any()} | 
    {:error, reason :: any()}

  @callback get(key(), state :: any()) :: 
    {:ok, value()} | 
    {:error, :not_found} | 
    {:error, reason :: any()}

  @callback delete(key(), state :: any()) :: 
    {:ok, state :: any()} | 
    {:error, reason :: any()}

  @callback list_keys(pattern :: binary(), state :: any()) :: 
    {:ok, [key()]} | 
    {:error, reason :: any()}

  @callback transaction(fun :: function(), state :: any()) :: 
    {:ok, result :: any(), state :: any()} | 
    {:error, reason :: any()}
end
```

## Core Data Structures

### Common Types

```elixir
defmodule Arbor.Types do
  @moduledoc """
  Common types used throughout the Arbor system.
  """

  # Type definitions
  @type agent_id :: binary()
  @type session_id :: binary()
  @type capability_id :: binary()
  @type trace_id :: binary()
  @type execution_id :: binary()
  @type resource_uri :: binary()
  @type agent_uri :: binary()
  @type timestamp :: DateTime.t()
  
  @type resource_type :: :fs | :api | :db | :tool | :agent
  @type operation :: :read | :write | :execute | :delete | :list
  @type agent_type :: :coordinator | :tool_executor | :llm | :export | :worker
  
  @type error :: {:error, error_reason()}
  @type error_reason :: atom() | binary() | map()
  
  # URI format validations
  @resource_uri_regex ~r/^arbor:\/\/[a-z]+\/[a-z]+\/.+$/
  @agent_uri_regex ~r/^arbor:\/\/agent\/[a-zA-Z0-9_-]+$/
  
  # ID format specifications
  @agent_id_prefix "agent_"
  @session_id_prefix "session_"
  @capability_id_prefix "cap_"
  @trace_id_prefix "trace_"
  @execution_id_prefix "exec_"
  
  # Guards
  defguard is_resource_type(type) when type in [:fs, :api, :db, :tool, :agent]
  defguard is_operation(op) when op in [:read, :write, :execute, :delete, :list]
  defguard is_agent_type(type) when type in [:coordinator, :tool_executor, :llm, :export, :worker]
  
  # Validation functions
  @spec valid_resource_uri?(binary()) :: boolean()
  def valid_resource_uri?(uri) when is_binary(uri) do
    Regex.match?(@resource_uri_regex, uri)
  end
  def valid_resource_uri?(_), do: false
  
  @spec valid_agent_uri?(binary()) :: boolean()
  def valid_agent_uri?(uri) when is_binary(uri) do
    Regex.match?(@agent_uri_regex, uri)
  end
  def valid_agent_uri?(_), do: false
  
  # ID Generation
  @spec generate_id(binary()) :: binary()
  def generate_id(prefix) when is_binary(prefix) do
    random_part = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    prefix <> random_part
  end
  
  @spec generate_agent_id() :: agent_id()
  def generate_agent_id, do: generate_id(@agent_id_prefix)
  
  @spec generate_session_id() :: session_id()
  def generate_session_id, do: generate_id(@session_id_prefix)
  
  @spec generate_capability_id() :: capability_id()
  def generate_capability_id, do: generate_id(@capability_id_prefix)
  
  @spec generate_trace_id() :: trace_id()
  def generate_trace_id, do: generate_id(@trace_id_prefix)
  
  @spec generate_execution_id() :: execution_id()
  def generate_execution_id, do: generate_id(@execution_id_prefix)
end
```

### Capability

```elixir
defmodule Arbor.Contracts.Core.Capability do
  @moduledoc """
  Represents a permission grant for resource access.
  
  This is the fundamental security primitive in the Arbor system.
  """
  
  use TypedStruct
  
  alias Arbor.Types
  
  @derive {Jason.Encoder, except: [:signature]}
  typedstruct enforce: true do
    @typedoc "A capability granting access to a specific resource"
    
    field :id, Types.capability_id()
    field :resource_uri, Types.resource_uri()
    field :principal_id, Types.agent_id()
    field :granted_at, Types.timestamp()
    field :expires_at, Types.timestamp(), enforce: false
    field :parent_capability_id, Types.capability_id(), enforce: false
    field :delegation_depth, non_neg_integer(), default: 3
    field :constraints, map(), default: %{}
    field :signature, binary(), enforce: false
    field :metadata, map(), default: %{}
  end
  
  @doc """
  Create a new capability with validation.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    capability = %__MODULE__{
      id: attrs[:id] || Types.generate_capability_id(),
      resource_uri: Keyword.fetch!(attrs, :resource_uri),
      principal_id: Keyword.fetch!(attrs, :principal_id),
      granted_at: attrs[:granted_at] || DateTime.utc_now(),
      expires_at: attrs[:expires_at],
      parent_capability_id: attrs[:parent_capability_id],
      delegation_depth: attrs[:delegation_depth] || 3,
      constraints: attrs[:constraints] || %{},
      metadata: attrs[:metadata] || %{}
    }
    
    case validate_capability(capability) do
      :ok -> {:ok, capability}
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp validate_capability(%__MODULE__{resource_uri: uri, principal_id: principal_id}) do
    cond do
      not Types.valid_resource_uri?(uri) ->
        {:error, {:invalid_resource_uri, uri}}
      
      not String.starts_with?(principal_id, "agent_") ->
        {:error, {:invalid_principal_id, principal_id}}
      
      true ->
        :ok
    end
  end
end
```

### Message Envelope

```elixir
defmodule Arbor.Contracts.Core.Message do
  @moduledoc """
  Standard message envelope for inter-agent communication.
  """
  
  use TypedStruct
  
  alias Arbor.Types
  
  typedstruct enforce: true do
    @typedoc "Message envelope for inter-agent communication"
    
    field :id, binary()
    field :to, Types.agent_uri()
    field :from, Types.agent_uri()
    field :session_id, Types.session_id(), enforce: false
    field :trace_id, Types.trace_id(), enforce: false
    field :execution_id, Types.execution_id(), enforce: false
    field :payload, any()
    field :timestamp, Types.timestamp()
    field :reply_to, binary(), enforce: false
    field :metadata, map(), default: %{}
  end
  
  @doc """
  Create a new message envelope with validation.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    message = %__MODULE__{
      id: attrs[:id] || Types.generate_id("msg_"),
      to: Keyword.fetch!(attrs, :to),
      from: Keyword.fetch!(attrs, :from),
      session_id: attrs[:session_id],
      trace_id: attrs[:trace_id],
      execution_id: attrs[:execution_id],
      payload: Keyword.fetch!(attrs, :payload),
      timestamp: attrs[:timestamp] || DateTime.utc_now(),
      reply_to: attrs[:reply_to],
      metadata: attrs[:metadata] || %{}
    }
    
    case validate_message(message) do
      :ok -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp validate_message(%__MODULE__{to: to, from: from}) do
    cond do
      not Types.valid_agent_uri?(to) ->
        {:error, {:invalid_to_uri, to}}
      
      not Types.valid_agent_uri?(from) ->
        {:error, {:invalid_from_uri, from}}
      
      true ->
        :ok
    end
  end
end
```

### Agent

```elixir
defmodule Arbor.Contracts.Core.Agent do
  @moduledoc """
  Core agent representation with metadata and capabilities.
  """
  
  use TypedStruct
  
  alias Arbor.Types
  alias Arbor.Contracts.Core.Capability
  
  typedstruct enforce: true do
    @typedoc "Agent instance representation"
    
    field :id, Types.agent_id()
    field :type, Types.agent_type()
    field :parent_id, Types.agent_id(), enforce: false
    field :session_id, Types.session_id()
    field :state, atom(), default: :active
    field :capabilities, [Capability.t()], default: []
    field :started_at, Types.timestamp()
    field :metadata, map(), default: %{}
  end
  
  @valid_states [:active, :inactive, :terminated, :error]
  
  @doc """
  Create a new agent with validation.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    agent = %__MODULE__{
      id: attrs[:id] || Types.generate_agent_id(),
      type: Keyword.fetch!(attrs, :type),
      parent_id: attrs[:parent_id],
      session_id: Keyword.fetch!(attrs, :session_id),
      state: attrs[:state] || :active,
      capabilities: attrs[:capabilities] || [],
      started_at: attrs[:started_at] || DateTime.utc_now(),
      metadata: attrs[:metadata] || %{}
    }
    
    case validate_agent(agent) do
      :ok -> {:ok, agent}
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp validate_agent(%__MODULE__{type: type, state: state}) do
    cond do
      not Types.is_agent_type(type) ->
        {:error, {:invalid_agent_type, type}}
      
      state not in @valid_states ->
        {:error, {:invalid_state, state}}
      
      true ->
        :ok
    end
  end
end
```

## Event Definitions

```elixir
defmodule Arbor.Contracts.Events.AgentEvents do
  @moduledoc """
  Events related to agent lifecycle and operations.
  """
  
  use TypedStruct
  
  alias Arbor.Types
  
  defmodule AgentStarted do
    use TypedStruct
    
    typedstruct enforce: true do
      field :agent_id, Types.agent_id()
      field :type, Types.agent_type()
      field :parent_id, Types.agent_id(), enforce: false
      field :session_id, Types.session_id()
      field :timestamp, Types.timestamp()
      field :metadata, map(), default: %{}
    end
  end
  
  defmodule AgentStopped do
    use TypedStruct
    
    typedstruct enforce: true do
      field :agent_id, Types.agent_id()
      field :reason, atom()
      field :timestamp, Types.timestamp()
      field :metadata, map(), default: %{}
    end
  end
  
  defmodule MessageSent do
    use TypedStruct
    
    typedstruct enforce: true do
      field :envelope, Arbor.Contracts.Core.Message.t()
      field :timestamp, Types.timestamp()
    end
  end
  
  defmodule CapabilityGranted do
    use TypedStruct
    
    typedstruct enforce: true do
      field :capability, Arbor.Contracts.Core.Capability.t()
      field :timestamp, Types.timestamp()
    end
  end
end
```

## Telemetry Events

```elixir
defmodule Arbor.Telemetry do
  @moduledoc """
  Standard telemetry events emitted by the system.
  """

  @doc """
  List of all standard telemetry events.
  
  Each event follows the pattern: [:arbor, subsystem, object, action]
  """
  def events do
    [
      # Agent lifecycle
      [:arbor, :agent, :start],
      [:arbor, :agent, :stop],
      [:arbor, :agent, :crash],
      
      # Message handling
      [:arbor, :message, :sent],
      [:arbor, :message, :received],
      [:arbor, :message, :dropped],
      
      # Tool execution
      [:arbor, :tool, :start],
      [:arbor, :tool, :stop],
      [:arbor, :tool, :exception],
      
      # Security
      [:arbor, :capability, :granted],
      [:arbor, :capability, :denied],
      [:arbor, :capability, :revoked],
      [:arbor, :capability, :validated],
      
      # Persistence
      [:arbor, :persistence, :snapshot, :saved],
      [:arbor, :persistence, :snapshot, :loaded],
      [:arbor, :persistence, :journal, :write],
      [:arbor, :persistence, :recovery, :complete]
    ]
  end
end
```

## Protocols

### Serializable

```elixir
defprotocol Arbor.Contracts.Serializable do
  @moduledoc """
  Protocol for converting between internal and external representations.
  """
  
  @doc "Convert to external representation (usually for JSON)"
  @spec to_external(t) :: map()
  def to_external(data)
  
  @doc "Convert from external representation"
  @spec from_external(map(), module()) :: {:ok, struct()} | {:error, term()}
  def from_external(data, target_module)
end

defimpl Arbor.Contracts.Serializable, for: Arbor.Contracts.Core.Capability do
  alias Arbor.Contracts.Core.Capability
  
  def to_external(cap) do
    %{
      "id" => cap.id,
      "resource_uri" => cap.resource_uri,
      "principal_id" => cap.principal_id,
      "granted_at" => DateTime.to_iso8601(cap.granted_at),
      "expires_at" => cap.expires_at && DateTime.to_iso8601(cap.expires_at),
      "parent_capability_id" => cap.parent_capability_id,
      "delegation_depth" => cap.delegation_depth,
      "constraints" => cap.constraints,
      "metadata" => cap.metadata
    }
  end
  
  def from_external(data, Capability) do
    with {:ok, granted_at} <- parse_datetime(data["granted_at"]),
         {:ok, expires_at} <- parse_optional_datetime(data["expires_at"]) do
      {:ok, %Capability{
        id: data["id"],
        resource_uri: data["resource_uri"],
        principal_id: data["principal_id"],
        granted_at: granted_at,
        expires_at: expires_at,
        parent_capability_id: data["parent_capability_id"],
        delegation_depth: data["delegation_depth"] || 3,
        constraints: data["constraints"] || %{},
        metadata: data["metadata"] || %{}
      }}
    end
  end
  
  defp parse_datetime(nil), do: {:error, :missing_datetime}
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> {:ok, dt}
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp parse_optional_datetime(nil), do: {:ok, nil}
  defp parse_optional_datetime(str), do: parse_datetime(str)
end
```

### Validatable

```elixir
defprotocol Arbor.Contracts.Validatable do
  @moduledoc """
  Protocol for validating structs.
  """
  
  @doc "Validate the struct, returning :ok or {:error, reasons}"
  @spec validate(t) :: :ok | {:error, term()}
  def validate(data)
end

defimpl Arbor.Contracts.Validatable, for: Arbor.Contracts.Core.Capability do
  alias Arbor.Types
  
  def validate(cap) do
    validators = [
      &validate_id/1,
      &validate_resource_uri/1,
      &validate_principal_id/1,
      &validate_expiration/1,
      &validate_delegation_depth/1
    ]
    
    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(cap) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
  
  defp validate_id(%{id: id}) do
    if String.starts_with?(id, "cap_") and String.length(id) == 36 do
      :ok
    else
      {:error, {:invalid_capability_id, id}}
    end
  end
  
  defp validate_resource_uri(%{resource_uri: uri}) do
    if Types.valid_resource_uri?(uri) do
      :ok
    else
      {:error, {:invalid_resource_uri, uri}}
    end
  end
  
  defp validate_principal_id(%{principal_id: id}) do
    if String.starts_with?(id, "agent_") do
      :ok
    else
      {:error, {:invalid_principal_id, id}}
    end
  end
  
  defp validate_expiration(%{granted_at: granted, expires_at: nil}), do: :ok
  defp validate_expiration(%{granted_at: granted, expires_at: expires}) do
    if DateTime.compare(expires, granted) == :gt do
      :ok
    else
      {:error, {:expires_before_granted, expires, granted}}
    end
  end
  
  defp validate_delegation_depth(%{delegation_depth: depth}) when depth >= 0 and depth <= 10 do
    :ok
  end
  defp validate_delegation_depth(%{delegation_depth: depth}) do
    {:error, {:invalid_delegation_depth, depth}}
  end
end
```

## Runtime Specifications (Norm)

```elixir
defmodule Arbor.Contracts.Specs.Core do
  @moduledoc """
  Runtime contract specifications for core entities using Norm.
  """
  
  import Norm
  alias Arbor.Types
  
  # Basic type specs
  def agent_id_spec, do: spec(is_binary() and &String.starts_with?(&1, "agent_"))
  def session_id_spec, do: spec(is_binary() and &String.starts_with?(&1, "session_"))
  def capability_id_spec, do: spec(is_binary() and &String.starts_with?(&1, "cap_"))
  
  def resource_uri_spec do
    spec(is_binary() and &Types.valid_resource_uri?/1)
  end
  
  def agent_uri_spec do
    spec(is_binary() and &Types.valid_agent_uri?/1)
  end
  
  # Core struct specs
  def capability_spec do
    schema(%{
      id: capability_id_spec(),
      resource_uri: resource_uri_spec(),
      principal_id: agent_id_spec(),
      granted_at: spec(&is_struct(&1, DateTime)),
      expires_at: spec(is_nil() or &is_struct(&1, DateTime)),
      delegation_depth: spec(is_integer() and &(&1 >= 0 and &1 <= 10))
    })
  end
  
  def message_spec do
    schema(%{
      id: spec(is_binary()),
      to: agent_uri_spec(),
      from: agent_uri_spec(),
      payload: spec(is_map()),
      timestamp: spec(&is_struct(&1, DateTime))
    })
  end
  
  # Validation function
  @spec validate(any(), atom()) :: :ok | {:error, [term()]}
  def validate(data, spec_name) do
    spec = apply(__MODULE__, :"#{spec_name}_spec", [])
    case conform(data, spec) do
      {:ok, _} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end
end
```

## Implementation Notes

1. **Zero Dependencies**: This app must have NO dependencies on other umbrella apps
2. **No Processes**: This app starts NO processes - it's purely compile-time contracts
3. **Backwards Compatibility**: Once published, changing these contracts requires careful versioning
4. **Documentation**: Every public type and callback must be thoroughly documented
5. **Dialyzer**: All modules must have complete typespecs for Dialyzer analysis

## Usage

Add to your dependencies:

```elixir
{:arbor_contracts, in_umbrella: true}
```

### Creating Structs

```elixir
alias Arbor.Contracts.Core.{Capability, Message, Agent}
alias Arbor.Types

# Create a capability
{:ok, cap} = Capability.new(
  resource_uri: "arbor://fs/read/home/user/documents",
  principal_id: Types.generate_agent_id(),
  expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
)

# Create a message
{:ok, msg} = Message.new(
  to: "arbor://agent/agent_abc123",
  from: "arbor://agent/agent_def456",
  payload: %{type: :request, data: "Hello"}
)
```

### Validation

```elixir
alias Arbor.Contracts.Validatable

# Validate a struct
case Validatable.validate(capability) do
  :ok -> # Valid
  {:error, reason} -> # Invalid
end
```

### Serialization

```elixir
alias Arbor.Contracts.Serializable

# Convert to external format (JSON-friendly)
external = Serializable.to_external(capability)

# Convert from external format
{:ok, cap} = Serializable.from_external(external_data, Capability)
```

### Runtime Contracts

```elixir
alias Arbor.Contracts.Specs.Core

# Validate against runtime contract
case Core.validate(capability, :capability) do
  :ok -> # Conforms to spec
  {:error, errors} -> # Contract violations
end
```