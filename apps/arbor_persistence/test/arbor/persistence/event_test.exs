defmodule Arbor.Persistence.EventTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Events.Event, as: ContractEvent
  alias Arbor.Persistence.Event

  describe "from_contract/1" do
    test "creates valid persistence event from contract event" do
      contract_event = %ContractEvent{
        id: "event_123",
        type: :agent_started,
        version: "1.0.0",
        aggregate_id: "agent_456",
        aggregate_type: :agent,
        data: %{agent_type: :llm},
        timestamp: ~U[2023-01-01 00:00:00Z],
        causation_id: nil,
        correlation_id: nil,
        trace_id: nil,
        stream_id: nil,
        stream_version: nil,
        global_position: nil,
        metadata: %{}
      }

      assert {:ok, %Event{}} = Event.from_contract(contract_event)
    end

    test "validates required fields are present" do
      invalid_event = %{
        type: :agent_started,
        data: %{agent_type: :llm}
        # Missing aggregate_id
      }

      assert {:error, {:validation_error, :invalid_contract_event}} =
               Event.from_contract(invalid_event)
    end

    test "rejects event with nil aggregate_id" do
      contract_event = %ContractEvent{
        id: "event_123",
        type: :agent_started,
        version: "1.0.0",
        # Invalid
        aggregate_id: nil,
        aggregate_type: :agent,
        data: %{agent_type: :llm},
        timestamp: ~U[2023-01-01 00:00:00Z],
        causation_id: nil,
        correlation_id: nil,
        trace_id: nil,
        stream_id: nil,
        stream_version: nil,
        global_position: nil,
        metadata: %{}
      }

      assert {:error, {:validation_error, :invalid_aggregate_id}} =
               Event.from_contract(contract_event)
    end

    test "sets stream_id from aggregate_id when missing" do
      contract_event = %ContractEvent{
        id: "event_123",
        type: :agent_started,
        version: "1.0.0",
        aggregate_id: "agent_456",
        aggregate_type: :agent,
        data: %{agent_type: :llm},
        timestamp: ~U[2023-01-01 00:00:00Z],
        causation_id: nil,
        correlation_id: nil,
        trace_id: nil,
        # Will be set from aggregate_id
        stream_id: nil,
        stream_version: nil,
        global_position: nil,
        metadata: %{}
      }

      {:ok, event} = Event.from_contract(contract_event)
      assert event.stream_id == "agent_456"
    end
  end

  describe "to_contract/1" do
    test "converts persistence event back to contract event" do
      event = %Event{
        id: "event_123",
        stream_id: "agent_456",
        stream_version: 1,
        event_type: :agent_started,
        event_data: %{agent_type: :llm},
        event_metadata: %{user_id: "user_123"},
        timestamp: ~U[2023-01-01 00:00:00Z],
        global_position: 1000,
        causation_id: nil,
        correlation_id: nil,
        trace_id: nil
      }

      assert {:ok, %ContractEvent{}} = Event.to_contract(event)
    end

    test "preserves all event data in roundtrip conversion" do
      original_contract = %ContractEvent{
        id: "event_123",
        type: :agent_started,
        version: "1.0.0",
        aggregate_id: "agent_456",
        aggregate_type: :agent,
        data: %{agent_type: :llm, capabilities: ["read", "write"]},
        timestamp: ~U[2023-01-01 00:00:00Z],
        causation_id: "cause_123",
        correlation_id: "corr_456",
        trace_id: "trace_789",
        stream_id: "agent_456",
        stream_version: 5,
        global_position: 1000,
        metadata: %{user_id: "user_123", session_id: "session_abc"}
      }

      {:ok, persistence_event} = Event.from_contract(original_contract)
      {:ok, roundtrip_contract} = Event.to_contract(persistence_event)

      # Core fields should match
      assert roundtrip_contract.id == original_contract.id
      assert roundtrip_contract.type == original_contract.type
      assert roundtrip_contract.aggregate_id == original_contract.aggregate_id
      assert roundtrip_contract.data == original_contract.data
      assert roundtrip_contract.timestamp == original_contract.timestamp
    end
  end
end
