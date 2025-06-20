# Schema-Driven Design for Arbor

## Overview

This document outlines the schema-driven approach for defining data structures, contracts, and interfaces in the Arbor umbrella application. By using a combination of Elixir-native tools and industry standards, we achieve type safety, validation, and clear contracts while maintaining developer productivity.

## Design Principles

1. **Native-First**: Leverage Elixir's ecosystem for internal contracts
2. **Standards for External APIs**: Use OpenAPI, JSON Schema for public interfaces
3. **Compile-Time Safety**: TypedStruct for catching errors early
4. **Runtime Validation**: Ecto changesets at system boundaries
5. **Progressive Enhancement**: Start simple, add complexity only when needed
6. **BEAM Philosophy Alignment**: Validate expected errors at boundaries, let unexpected errors crash cleanly

> 💡 **Philosophy Note**: This schema-driven approach enhances rather than contradicts BEAM's "let it crash" philosophy. See [BEAM_PHILOSOPHY_AND_CONTRACTS.md](./BEAM_PHILOSOPHY_AND_CONTRACTS.md) for detailed analysis of how contracts enable better crash semantics.

## Technology Stack

### Core Technologies

| Technology | Purpose | Scope |
|------------|---------|--------|
| **TypedStruct** | Compile-time type checking for structs | Internal data structures |
| **Ecto** | Data validation and transformation | API boundaries |
| **Norm** | Runtime contract verification | Inter-service contracts |
| **OpenAPI** | REST API documentation | External HTTP APIs |
| **JSON Schema** | JSON validation | External data exchange |
| **ExJsonSchema** | JSON Schema validation in Elixir | API request/response validation |

### Optional Enhancements

- **Absinthe**: GraphQL API with subscriptions
- **Protocol Buffers**: Binary serialization for external APIs
- **Apache Avro**: Schema evolution for event streaming

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    External Clients                          │
│                  (REST, GraphQL, WebSocket)                  │
└────────────────────────┬────────────────────────────────────┘
                         │
                    OpenAPI/GraphQL
                         │
┌────────────────────────┴────────────────────────────────────┐
│                    Validation Layer                          │
│              (Ecto Changesets, JSON Schema)                  │
└────────────────────────┬────────────────────────────────────┘
                         │
                 Validated Data Objects
                         │
┌────────────────────────┴────────────────────────────────────┐
│                    Core Contracts                            │
│              (TypedStruct, Norm Specs)                       │
└────────────────────────┬────────────────────────────────────┘
                         │
              Internal Service Communication
                         │
┌────────────────────────┴────────────────────────────────────┐
│                    Services                                  │
│        (Agents, Security, Persistence, etc.)                 │
└─────────────────────────────────────────────────────────────┘
```

## Layered Contract Strategy

### Layer 1: Core Contracts (TypedStruct)

The foundation layer defines all shared data structures using TypedStruct for compile-time guarantees.

**Location**: `apps/arbor_contracts/`

**Example**:
```elixir
defmodule Arbor.Contracts.Message do
  use TypedStruct
  
  @derive {Jason.Encoder, only: [:id, :type, :payload, :sender_id, :timestamp]}
  typedstruct enforce: true do
    field :id, String.t()
    field :type, atom()
    field :payload, map()
    field :sender_id, String.t()
    field :timestamp, DateTime.t()
    field :metadata, map(), default: %{}
  end
end
```

### Layer 2: Validation (Ecto)

At system boundaries, we validate and transform external data into our core contracts.

**Location**: Within each app that has external interfaces

**Example**:
```elixir
defmodule Arbor.Web.Validators.MessageInput do
  use Ecto.Schema
  import Ecto.Changeset
  
  @primary_key false
  embedded_schema do
    field :type, :string
    field :payload, :map
    field :sender_id, :string
  end
  
  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:type, :payload, :sender_id])
    |> validate_required([:type, :payload, :sender_id])
    |> validate_inclusion(:type, ~w(text command event))
    |> validate_payload()
  end
  
  defp validate_payload(changeset) do
    # Custom validation logic based on message type
    changeset
  end
end
```

### Layer 3: Runtime Contracts (Norm)

For critical inter-service boundaries, we can add runtime contract verification.

**Location**: `apps/arbor_contracts/lib/arbor/contracts/specs/`

**Example**:
```elixir
defmodule Arbor.Contracts.Specs do
  import Norm
  
  def capability_request do
    schema(%{
      resource_type: spec(is_atom() and &(&1 in [:fs, :api, :db, :tool])),
      operation: spec(is_atom() and &(&1 in [:read, :write, :execute, :delete])),
      resource_path: spec(is_binary() and &valid_path?/1),
      constraints: spec(is_map())
    })
  end
  
  defp valid_path?(path) do
    not String.contains?(path, "..")
  end
end
```

### Layer 4: External APIs (OpenAPI/GraphQL)

Public APIs are documented using industry standards.

**Location**: `apps/arbor_web/priv/openapi/`

**Example**:
```yaml
components:
  schemas:
    Message:
      type: object
      required: [type, payload, sender_id]
      properties:
        type:
          type: string
          enum: [text, command, event]
        payload:
          type: object
        sender_id:
          type: string
          format: uuid
```

## Implementation Patterns

### Pattern 1: Struct to Validation to Contract

```elixir
# 1. Define core struct
defmodule Arbor.Contracts.Agent do
  use TypedStruct
  
  typedstruct do
    field :id, String.t()
    field :type, atom()
    field :capabilities, [Arbor.Contracts.Capability.t()], default: []
  end
end

# 2. Create validator
defmodule Arbor.Web.Validators.AgentInput do
  use Ecto.Schema
  import Ecto.Changeset
  
  embedded_schema do
    field :type, :string
    embeds_many :capabilities, CapabilityInput
  end
  
  def to_contract(%Ecto.Changeset{valid?: true} = changeset) do
    data = apply_action!(changeset, :insert)
    {:ok, %Arbor.Contracts.Agent{
      id: Ecto.UUID.generate(),
      type: String.to_atom(data.type),
      capabilities: Enum.map(data.capabilities, &CapabilityInput.to_contract/1)
    }}
  end
  
  def to_contract(%Ecto.Changeset{} = changeset) do
    {:error, changeset}
  end
end

# 3. Use in controller
def create(conn, %{"agent" => agent_params}) do
  with {:ok, validated} <- AgentInput.changeset(agent_params) |> AgentInput.to_contract(),
       {:ok, agent} <- Arbor.Core.create_agent(validated) do
    json(conn, agent)
  end
end
```

### Pattern 2: Protocol-Based Serialization

```elixir
defprotocol Arbor.Contracts.Serializable do
  @doc "Convert to external representation"
  def to_external(data)
  
  @doc "Convert from external representation"
  def from_external(data, type)
end

defimpl Arbor.Contracts.Serializable, for: Arbor.Contracts.Capability do
  def to_external(cap) do
    %{
      "id" => cap.id,
      "resource_uri" => cap.resource_uri,
      "granted_at" => DateTime.to_iso8601(cap.granted_at),
      "expires_at" => cap.expires_at && DateTime.to_iso8601(cap.expires_at)
    }
  end
  
  def from_external(data, Arbor.Contracts.Capability) do
    # Validation and transformation
  end
end
```

### Pattern 3: Contract Testing

```elixir
defmodule Arbor.Contracts.MessageTest do
  use ExUnit.Case
  use ExUnitProperties
  
  property "all valid messages conform to spec" do
    check all type <- member_of([:text, :command, :event]),
              payload <- map_of(string(:ascii), term()),
              sender_id <- string(:ascii, min_length: 1) do
      
      message = %Arbor.Contracts.Message{
        id: Ecto.UUID.generate(),
        type: type,
        payload: payload,
        sender_id: sender_id,
        timestamp: DateTime.utc_now()
      }
      
      assert Norm.valid?(message, Arbor.Contracts.Specs.message())
    end
  end
end
```

## Benefits

### 1. Type Safety
- Compile-time checks with TypedStruct
- Dialyzer integration for static analysis
- Clear struct definitions with enforced fields

### 2. Validation Power
- Ecto's changeset pipeline for complex validation
- Composable validation functions
- Clear error messages for clients

### 3. Contract Verification
- Runtime checks with Norm where needed
- Property-based testing support
- Contract evolution tracking

### 4. Developer Experience
- Native Elixir tools and patterns
- No code generation step
- Excellent documentation through types

### 5. Interoperability
- Standard formats for external APIs
- JSON Schema for validation
- OpenAPI for client generation

## Migration Strategy

### From Current Codebase

1. **Phase 1: Extract Contracts**
   - Create `arbor_contracts` app
   - Move existing structs, add TypedStruct
   - No behavior changes

2. **Phase 2: Add Validation**
   - Create Ecto schemas for API inputs
   - Replace manual validation with changesets
   - Add property tests

3. **Phase 3: External APIs**
   - Generate OpenAPI from routes
   - Add JSON Schema validation
   - Enable client generation

4. **Phase 4: Runtime Contracts**
   - Add Norm specs for critical paths
   - Enable contract checking in dev/test
   - Performance testing

## Best Practices

### 1. Struct Design
- Use TypedStruct for all shared structs
- Enforce required fields
- Provide sensible defaults
- Derive Jason.Encoder strategically

### 2. Validation
- Validate at system boundaries only
- Use embedded schemas for nested data
- Create reusable validation functions
- Return clear, actionable errors

### 3. Documentation
- Document all public structs
- Include examples in @moduledoc
- Generate API docs from OpenAPI
- Keep specs and code in sync

### 4. Testing
- Property test all contracts
- Test validation edge cases
- Verify serialization round-trips
- Contract conformance tests

## Anti-Patterns to Avoid

### 1. Over-Validation
Don't validate the same data multiple times. Trust your internal contracts.

### 2. Stringly-Typed Data
Use atoms for internal enums, convert at boundaries.

### 3. Contract Sprawl
Keep contracts focused. Not every struct needs a full contract.

### 4. Premature Abstraction
Start with TypedStruct and Ecto. Add complexity only when needed.

## Tools and Libraries

### Required Dependencies
```elixir
# apps/arbor_contracts/mix.exs
defp deps do
  [
    {:typed_struct, "~> 0.3"},
    {:ecto, "~> 3.11"},
    {:jason, "~> 1.4"},
    {:norm, "~> 0.13", runtime: false}
  ]
end
```

### Optional Dependencies
```elixir
# For API apps
{:ex_json_schema, "~> 0.10"},
{:open_api_spex, "~> 3.18"},

# For GraphQL
{:absinthe, "~> 1.7"},

# For binary protocols
{:protobuf, "~> 0.12"},
{:avro_ex, "~> 2.0"}
```

## Serialization Format Comparison

### Native BEAM Terms (ETF - External Term Format)

The BEAM's native serialization format, used by default for Erlang/Elixir distribution.

**Best for**: Internal agent-to-agent communication within your Elixir cluster

**Pros**:
- **Zero overhead** for same-node communication (just pointer passing)
- **Minimal overhead** for cross-node BEAM communication (~50-200 microseconds)
- **Native pattern matching** - can match directly on message shapes
- **No serialization bugs** - what you send is exactly what arrives
- **Process mailbox efficiency** - messages stay in native format

**Cons**:
- **No schema validation** - runtime errors if structure changes
- **Larger wire size** than binary formats (atoms sent as strings, typically 2-5x larger than Protobuf)
- **BEAM-only** - cannot communicate with non-BEAM services
- **No built-in versioning** - manual migration strategies needed

### Protocol Buffers

Google's binary serialization format with schema definition and code generation.

**Best for**: REST APIs, WebSocket messages, external service integration

**Pros**:
- **Compact binary format** - typically 30-70% smaller than JSON
- **Fast serialization** - ~5-50 microseconds for typical messages
- **Type safety** with code generation
- **Excellent tooling** - viewers, debuggers, documentation generators
- **Wide language support** - clients for virtually every language
- **Schema evolution** - backward/forward compatibility built-in

**Cons**:
- **Extra build step** - need to compile .proto files
- **Version management** - need to distribute .proto files
- **Not self-describing** - need schema to decode
- **Limited type system** - no native support for atoms, tuples
- **Overhead for internal communication** - unnecessary within BEAM cluster

### Apache Avro

Schema evolution-focused format with self-describing capabilities.

**Best for**: Event sourcing, Kafka integration, data lake storage

**Pros**:
- **Schema evolution** is first-class (reader/writer schema compatibility)
- **Self-describing** - schema can be embedded or in registry
- **Compact** like Protobuf
- **Dynamic typing** - can work with data without code generation
- **Strong big data ecosystem** integration

**Cons**:
- **Weaker Elixir ecosystem** - fewer libraries, less mature
- **Complex schema resolution** - runtime overhead
- **JSON schema syntax** - more verbose than .proto files
- **Less common** for general RPC compared to Protobuf

## Serialization Strategy for Arbor

### Recommended Hybrid Approach

Use different serialization formats for different communication patterns:

```elixir
defmodule Arbor.Serialization do
  @moduledoc """
  Unified serialization strategy for Arbor
  """
  
  # Internal BEAM-to-BEAM: No serialization needed
  def prepare_internal_message(data), do: data
  
  # External APIs: Protocol Buffers
  def prepare_external_message(data, :protobuf) do
    data
    |> to_proto_struct()
    |> MyProto.Message.encode()
  end
  
  # Legacy support: JSON
  def prepare_external_message(data, :json) do
    data
    |> to_external_map()
    |> Jason.encode!()
  end
  
  # Event streaming: Avro
  def prepare_event_stream_message(data, schema) do
    data
    |> to_avro_map()
    |> Avrora.encode(schema: schema)
  end
end
```

### Performance Comparison

For a typical chat message:

| Format | Wire Size | Encode Time | Decode Time | Use Case |
|--------|-----------|-------------|-------------|----------|
| ETF (Native) | ~200 bytes | ~0.5 μs | ~0.5 μs | Internal BEAM |
| Protocol Buffers | ~80 bytes | ~10 μs | ~8 μs | External APIs |
| JSON | ~150 bytes | ~15 μs | ~20 μs | Web/Debug |
| Avro | ~85 bytes | ~12 μs | ~10 μs | Event Streams |

### Decision Framework

1. **Is communication within BEAM cluster?**
   - YES → Use native BEAM terms (ETF)
   - NO → Continue to #2

2. **Do you need schema evolution and/or Kafka?**
   - YES → Use Avro with schema registry
   - NO → Continue to #3

3. **Do you need maximum performance and type safety?**
   - YES → Use Protocol Buffers
   - NO → JSON is acceptable for simple cases

### Key Insights

- **The BEAM is already optimized** for distributed Erlang/Elixir systems
- **Don't serialize unnecessarily** - native terms are fastest within BEAM
- **Use binary formats at boundaries** - Protobuf for APIs, Avro for streams
- **Benchmark your use case** - these numbers are guidelines, not absolutes

## Conclusion

This schema-driven approach provides the benefits of strong typing and validation while remaining pragmatic and Elixir-native. It scales from simple internal contracts to complex external APIs without requiring a complete architectural overhaul. The hybrid serialization strategy leverages the BEAM's native efficiency for internal communication while providing robust, interoperable formats for external integration.