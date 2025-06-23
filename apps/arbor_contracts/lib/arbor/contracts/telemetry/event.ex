defmodule Arbor.Contracts.Telemetry.Event do
  @moduledoc """
  Defines the base contract for all telemetry events in the Arbor system.

  This module establishes a common structure and behavior for telemetry events,
  ensuring consistency in how observability data is structured and validated.
  All specific event types (e.g., AgentEvent, ReconciliationEvent) should
  adhere to this fundamental contract.
  """

  @typedoc "The base type for any telemetry event."
  @type t :: %__MODULE__{
          event_name: event_name(),
          measurements: measurements(),
          metadata: metadata(),
          timestamp: integer(),
          node: atom()
        }

  @typedoc "A list of atoms defining the event's hierarchical name (e.g., [:arbor, :agent, :restarted])."
  @type event_name :: list(atom())

  @typedoc "A map of numerical measurements associated with the event (e.g., %{duration_ms: 120})."
  @type measurements :: map()

  @typedoc "A map of non-numerical context associated with the event (e.g., %{agent_id: \"agent-123\"})."
  @type metadata :: map()

  defstruct [
    :event_name,
    :measurements,
    :metadata,
    :timestamp,
    :node
  ]

  @doc """
  A behavior that all specific event contracts must implement.
  This ensures that every event type can be validated.
  """
  @callback validate(t()) :: :ok | {:error, term()}

  @doc """
  Creates a new telemetry event.

  Automatically populates the `timestamp` and `node` fields.
  """
  @spec new(event_name(), measurements(), metadata()) :: t()
  def new(event_name, measurements, metadata) do
    %__MODULE__{
      event_name: event_name,
      measurements: measurements,
      metadata: metadata,
      timestamp: System.system_time(:native),
      node: node()
    }
  end

  @doc """
  Validates the structure of a base telemetry event.

  Checks for the presence and correct types of core fields.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{
        event_name: name,
        measurements: m,
        metadata: meta,
        timestamp: ts,
        node: n
      })
      when is_list(name) and is_map(m) and is_map(meta) and is_integer(ts) and is_atom(n) do
    :ok
  end

  def validate(_other) do
    {:error, :invalid_base_event_structure}
  end
end
