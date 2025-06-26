defmodule Arbor.Persistence.FastCase do
  @moduledoc """
  ExUnit case template for fast unit tests using in-memory persistence.

  This case template provides:
  - In-memory persistence backend for maximum speed
  - Isolated test environment with unique table names
  - Same API as IntegrationCase for consistency
  - Integration with Arbor's event sourcing patterns

  ## Usage

      defmodule MyModule.UnitTest do
        use Arbor.Persistence.FastCase

        test "creates and reads events", %{store: store} do
          event = build_test_event(:agent_started)
          
          {:ok, _version} = Store.append_events("test-stream", [event], -1, store)
          {:ok, events} = Store.read_events("test-stream", 0, :latest, store)
          
          assert length(events) == 1
        end
      end

  ## Test Tags

  All tests using this case are automatically tagged with:
  - `persistence: :mock` - Uses in-memory persistence
  - `:fast` - Indicates fast unit test
  - `async: true` - Safe for parallel execution

  ## Provided Helpers

  - `build_test_event/2` - Creates test events with realistic data
  - `build_test_snapshot/2` - Creates test snapshots
  - `unique_stream_id/1` - Generates unique stream identifiers
  """

  use ExUnit.CaseTemplate

  alias Arbor.Contracts.Events.Event, as: ContractEvent
  alias Arbor.Contracts.Persistence.Snapshot
  alias Arbor.Persistence.Store

  using do
    quote do
      # Import common modules for convenience in tests
      import Ecto
      import Ecto.Query
      import Arbor.Persistence.FastCase

      # Always use async: true for fast unit tests
      use ExUnit.Case, async: true

      # Standard aliases for consistency with IntegrationCase
      alias Arbor.Contracts.Events.Event, as: ContractEvent
      alias Arbor.Contracts.Persistence.Snapshot
      alias Arbor.Persistence.Store
    end
  end

  # Tag all tests using this case
  @moduletag persistence: :mock
  @moduletag :fast

  setup do
    # Create unique table name to avoid conflicts in parallel tests
    table_name = :"test_store_#{:erlang.unique_integer([:positive])}"

    # Initialize in-memory store
    {:ok, store} = Store.init(backend: :in_memory, table_name: table_name)

    %{store: store, table_name: table_name}
  end

  @doc """
  Creates a test event with realistic data.

  ## Parameters
  - `type` - Event type atom (e.g., `:agent_started`)
  - `opts` - Optional overrides (keyword list)

  ## Examples
      
      event = build_test_event(:agent_started)
      event = build_test_event(:agent_message_sent, aggregate_id: "custom-id")
  """
  def build_test_event(type, opts \\ []) do
    base_id = :erlang.unique_integer([:positive])

    defaults = [
      id: Ecto.UUID.generate(),
      type: type,
      version: "1.0.0",
      aggregate_id: "test_aggregate_#{base_id}",
      aggregate_type: :agent,
      data: build_event_data(type),
      timestamp: DateTime.utc_now(),
      causation_id: nil,
      correlation_id: "test_correlation_#{base_id}",
      trace_id: "test_trace_#{base_id}",
      stream_id: "test-stream-#{base_id}",
      stream_version: 0,
      global_position: nil,
      metadata: %{test: true, case: "fast"}
    ]

    merged_opts = Keyword.merge(defaults, opts)
    struct!(ContractEvent, merged_opts)
  end

  @doc """
  Creates a test snapshot with realistic data.

  ## Parameters
  - `aggregate_id` - The aggregate identifier
  - `opts` - Optional overrides (keyword list)
  """
  def build_test_snapshot(aggregate_id, opts \\ []) do
    defaults = [
      id: Ecto.UUID.generate(),
      aggregate_id: aggregate_id,
      aggregate_type: :agent,
      aggregate_version: 1,
      snapshot_version: 1,
      state: %{state: "test_state", counter: 42},
      state_hash: "test_hash",
      metadata: %{test: true, case: "fast"},
      created_at: DateTime.utc_now()
    ]

    merged_opts = Keyword.merge(defaults, opts)
    struct!(Snapshot, merged_opts)
  end

  @doc """
  Generates a unique stream identifier for testing.

  ## Parameters
  - `prefix` - Optional prefix for the stream name (default: "test-stream")

  ## Examples
      
      stream_id = unique_stream_id()
      stream_id = unique_stream_id("agent-lifecycle")
  """
  def unique_stream_id(prefix \\ "test-stream") do
    "#{prefix}-#{:erlang.unique_integer([:positive])}"
  end

  @doc """
  Creates multiple test events for a stream.

  ## Parameters
  - `stream_id` - The stream identifier
  - `event_types` - List of event types to create
  - `opts` - Optional overrides applied to all events

  ## Examples
      
      events = build_event_sequence("test-stream", [:agent_started, :agent_message_sent])
  """
  def build_event_sequence(stream_id, event_types, opts \\ []) do
    event_types
    |> Enum.with_index()
    |> Enum.map(fn {type, index} ->
      build_test_event(
        type,
        [
          stream_id: stream_id,
          stream_version: index,
          aggregate_id: stream_id
        ] ++ opts
      )
    end)
  end

  # Private helper to generate realistic event data based on type
  defp build_event_data(:agent_started) do
    %{
      agent_type: "test_agent",
      model: "test-model-1.0",
      capabilities: ["text_generation", "analysis"],
      config: %{temperature: 0.7, max_tokens: 1000}
    }
  end

  defp build_event_data(:agent_message_sent) do
    %{
      message_id: Ecto.UUID.generate(),
      content: "This is a test message",
      role: "assistant",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp build_event_data(:agent_stopped) do
    %{
      reason: "test_completion",
      final_state: "completed",
      metrics: %{
        messages_processed: 5,
        execution_time_ms: 1500,
        tokens_used: 250
      }
    }
  end

  defp build_event_data(:session_created) do
    %{
      session_id: Ecto.UUID.generate(),
      user_id: "test_user_123",
      preferences: %{
        theme: "dark",
        language: "en"
      }
    }
  end

  defp build_event_data(_unknown_type) do
    %{
      test: "generic_event_data",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
