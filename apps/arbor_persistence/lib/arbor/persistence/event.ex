defmodule Arbor.Persistence.Event do
  @moduledoc """
  Internal persistence representation of events.

  This module provides conversion between the contract Event schema
  and the internal persistence format optimized for storage.

  IMPORTANT: This is for persistence layer use only. All external
  interactions should use Arbor.Contracts.Events.Event.
  """

  use TypedStruct

  alias Arbor.Contracts.Events.Event, as: ContractEvent

  typedstruct enforce: true do
    @typedoc "Internal persistence event structure"

    # Stream positioning
    field(:id, String.t())
    field(:stream_id, String.t())
    field(:stream_version, non_neg_integer())
    field(:global_position, non_neg_integer(), enforce: false)

    # Event content
    field(:event_type, atom())
    field(:event_data, map())
    field(:event_metadata, map(), default: %{})

    # Timing
    field(:timestamp, DateTime.t())

    # Tracing
    field(:causation_id, String.t(), enforce: false)
    field(:correlation_id, String.t(), enforce: false)
    field(:trace_id, String.t(), enforce: false)
  end

  @doc """
  Convert a contract event to internal persistence format.

  Validates the event and prepares it for storage.
  """
  @spec from_contract(ContractEvent.t()) :: {:ok, t()} | {:error, term()}
  def from_contract(%ContractEvent{} = contract_event) do
    with :ok <- validate_contract_event(contract_event) do
      persistence_event = %__MODULE__{
        id: contract_event.id,
        stream_id: contract_event.stream_id || contract_event.aggregate_id,
        stream_version: contract_event.stream_version || 0,
        global_position: contract_event.global_position,
        event_type: contract_event.type,
        event_data: contract_event.data,
        event_metadata: contract_event.metadata,
        timestamp: contract_event.timestamp,
        causation_id: contract_event.causation_id,
        correlation_id: contract_event.correlation_id,
        trace_id: contract_event.trace_id
      }

      {:ok, persistence_event}
    end
  end

  def from_contract(_invalid) do
    {:error, {:validation_error, :invalid_contract_event}}
  end

  @doc """
  Convert internal persistence event back to contract format.
  """
  @spec to_contract(t()) :: {:ok, ContractEvent.t()} | {:error, term()}
  def to_contract(%__MODULE__{} = persistence_event) do
    contract_event = %ContractEvent{
      id: persistence_event.id,
      type: persistence_event.event_type,
      # Default version for now
      version: "1.0.0",
      aggregate_id: persistence_event.stream_id,
      aggregate_type: infer_aggregate_type(persistence_event.stream_id),
      data: persistence_event.event_data,
      timestamp: persistence_event.timestamp,
      causation_id: persistence_event.causation_id,
      correlation_id: persistence_event.correlation_id,
      trace_id: persistence_event.trace_id,
      stream_id: persistence_event.stream_id,
      stream_version: persistence_event.stream_version,
      global_position: persistence_event.global_position,
      metadata: persistence_event.event_metadata
    }

    {:ok, contract_event}
  end

  # Private functions

  defp validate_contract_event(%ContractEvent{aggregate_id: nil}) do
    {:error, {:validation_error, :invalid_aggregate_id}}
  end

  defp validate_contract_event(%ContractEvent{aggregate_id: ""}),
    do: {:error, {:validation_error, :invalid_aggregate_id}}

  defp validate_contract_event(%ContractEvent{type: nil}) do
    {:error, {:validation_error, :missing_event_type}}
  end

  defp validate_contract_event(%ContractEvent{data: nil}) do
    {:error, {:validation_error, :missing_event_data}}
  end

  defp validate_contract_event(_), do: :ok

  defp infer_aggregate_type(stream_id) when is_binary(stream_id) do
    case String.split(stream_id, "_", parts: 2) do
      [prefix, _] -> String.to_atom(prefix)
      _ -> :unknown
    end
  end

  defp infer_aggregate_type(_), do: :unknown
end
