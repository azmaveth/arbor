defmodule Arbor.Persistence.Unit.EventSourcingUtilitiesTest do
  @moduledoc """
  Example tests demonstrating the event sourcing test utilities.

  This test module shows how to use all the event sourcing test helpers
  together to write comprehensive tests for event-sourced systems.
  """

  use Arbor.Persistence.FastCase

  # Import all the test utilities
  import Arbor.Persistence.EventStreamAssertions
  import Arbor.Persistence.AggregateTestHelper
  import Arbor.Persistence.ProjectionTestHelper
  import Arbor.Persistence.EventPatternMatcher
  import Arbor.Persistence.EventTimeMachine

  describe "EventStreamAssertions" do
    test "verifies event sequences and ordering", %{store: store} do
      stream_id = unique_stream_id("assertions")

      events =
        build_event_sequence(stream_id, [
          :agent_started,
          :agent_configured,
          :agent_activated,
          :agent_message_sent,
          :agent_stopped
        ])

      {:ok, _} = Store.append_events(stream_id, events, -1, store)

      # Verify exact sequence
      assert_event_sequence(
        stream_id,
        [
          :agent_started,
          :agent_configured,
          :agent_activated,
          :agent_message_sent,
          :agent_stopped
        ],
        store
      )

      # Verify subsequence (non-strict)
      assert_event_sequence(
        stream_id,
        [
          :agent_started,
          :agent_activated,
          :agent_stopped
        ],
        store,
        strict: false
      )

      # Verify stream version
      assert_stream_version(stream_id, 4, store)

      # Verify timestamp ordering
      assert_timestamp_ordering(stream_id, store)

      # Verify no events after version 4
      refute_events_after(stream_id, 4, store)
    end

    test "verifies causality chains", %{store: store} do
      stream_id = unique_stream_id("causality")
      base_id = Ecto.UUID.generate()

      # Create events with causality chain
      event1 =
        build_test_event(:command_received,
          stream_id: stream_id,
          id: base_id,
          stream_version: 0
        )

      event2 =
        build_test_event(:agent_started,
          stream_id: stream_id,
          causation_id: base_id,
          stream_version: 1
        )

      event3 =
        build_test_event(:agent_configured,
          stream_id: stream_id,
          causation_id: event2.id,
          stream_version: 2
        )

      {:ok, _} = Store.append_events(stream_id, [event1, event2, event3], -1, store)
      {:ok, events} = Store.read_events(stream_id, 0, :latest, store)

      # Verify strict causality chain
      assert_causality_chain(events)
    end
  end

  describe "AggregateTestHelper" do
    test "reconstructs aggregate state from events", %{store: store} do
      aggregate_id = unique_stream_id("aggregate")

      events = [
        build_test_event(:agent_started,
          stream_id: aggregate_id,
          aggregate_id: aggregate_id,
          stream_version: 0,
          data: %{status: :initializing, model: "claude-3"}
        ),
        build_test_event(:agent_configured,
          stream_id: aggregate_id,
          aggregate_id: aggregate_id,
          stream_version: 1,
          data: %{temperature: 0.7, max_tokens: 2048}
        ),
        build_test_event(:agent_activated,
          stream_id: aggregate_id,
          aggregate_id: aggregate_id,
          stream_version: 2,
          data: %{status: :active}
        ),
        build_test_event(:agent_message_sent,
          stream_id: aggregate_id,
          aggregate_id: aggregate_id,
          stream_version: 3
        ),
        build_test_event(:agent_message_sent,
          stream_id: aggregate_id,
          aggregate_id: aggregate_id,
          stream_version: 4
        )
      ]

      {:ok, _} = Store.append_events(aggregate_id, events, -1, store)

      # Replay to current state
      state = replay_to_aggregate(aggregate_id, store)
      assert state.status == :active
      assert state.model == "claude-3"
      assert state.temperature == 0.7
      assert state.message_count == 2

      # Assert specific state values
      assert_aggregate_state(
        aggregate_id,
        %{
          status: :active,
          message_count: 2,
          model: "claude-3"
        },
        store
      )

      # Get state at specific version
      state_v1 = get_aggregate_at_version(aggregate_id, 1, store)
      assert state_v1.status == :initializing
      assert Map.get(state_v1, :message_count) == nil

      # Compare versions
      {:ok, changes} = diff_aggregate_versions(aggregate_id, 1, 4, store)
      assert changes.status == {:initializing, :active}
      assert Map.get(changes, :message_count) == {nil, 2}
    end

    test "validates aggregate invariants", %{store: store} do
      account_id = unique_stream_id("account")

      events = [
        build_test_event(:account_opened,
          stream_id: account_id,
          aggregate_id: account_id,
          stream_version: 0,
          data: %{balance: 1000}
        ),
        build_test_event(:amount_deposited,
          stream_id: account_id,
          aggregate_id: account_id,
          stream_version: 1,
          data: %{amount: 500, balance: 1500}
        ),
        build_test_event(:amount_withdrawn,
          stream_id: account_id,
          aggregate_id: account_id,
          stream_version: 2,
          data: %{amount: 200, balance: 1300}
        )
      ]

      {:ok, _} = Store.append_events(account_id, events, -1, store)

      # Balance should never be negative
      assert_aggregate_invariant(
        account_id,
        fn state ->
          Map.get(state, :balance, 0) >= 0
        end,
        store
      )
    end
  end

  describe "ProjectionTestHelper" do
    test "builds projections from events", %{store: store} do
      # Create events across multiple streams
      agent1_id = unique_stream_id("agent")
      agent2_id = unique_stream_id("agent")

      {:ok, _} =
        Store.append_events(
          agent1_id,
          [
            build_test_event(:agent_started, stream_id: agent1_id, aggregate_id: agent1_id),
            build_test_event(:agent_activated, stream_id: agent1_id, aggregate_id: agent1_id)
          ],
          -1,
          store
        )

      {:ok, _} =
        Store.append_events(
          agent2_id,
          [
            build_test_event(:agent_started, stream_id: agent2_id, aggregate_id: agent2_id),
            build_test_event(:agent_activated, stream_id: agent2_id, aggregate_id: agent2_id),
            build_test_event(:agent_stopped, stream_id: agent2_id, aggregate_id: agent2_id)
          ],
          -1,
          store
        )

      # Build projection
      projection =
        build_projection(
          Arbor.Persistence.ProjectionTestHelper.ExampleProjections.AgentCountProjection,
          store
        )

      # Agent 1: started -> activated (total +1, active +1, started -1) 
      # Agent 2: started -> activated -> stopped (total +1, active +1, started -1, then total -1, active -1)
      # Final state: total = 1, active = 1
      # One agent still in system
      assert projection.total == 1
      # Agent 1 is active
      assert projection.by_status.active == 1

      # Assert specific projection values
      assert_projection_matches(projection, %{
        total: 1,
        by_status: %{active: 1, started: 0}
      })
    end

    test "compares projections", %{store: store} do
      agent_id = unique_stream_id("agent")

      # Initial state
      projection1 =
        build_projection(
          Arbor.Persistence.ProjectionTestHelper.ExampleProjections.AgentCountProjection,
          store
        )

      # Add events
      {:ok, _} =
        Store.append_events(
          agent_id,
          [
            build_test_event(:agent_started, stream_id: agent_id, aggregate_id: agent_id),
            build_test_event(:agent_activated, stream_id: agent_id, aggregate_id: agent_id)
          ],
          -1,
          store
        )

      # New state
      projection2 =
        build_projection(
          Arbor.Persistence.ProjectionTestHelper.ExampleProjections.AgentCountProjection,
          store
        )

      # Compare
      {:ok, diff} = compare_projections(projection1, projection2)
      assert diff != :identical
      assert diff.total == {0, 1}
    end
  end

  describe "EventPatternMatcher" do
    test "validates command-event patterns", %{store: store} do
      command_id = Ecto.UUID.generate()
      stream_id = unique_stream_id("pattern")

      # Simulate command execution that produces events
      events = [
        build_test_event(:order_placed,
          stream_id: stream_id,
          correlation_id: command_id,
          stream_version: 0,
          data: %{order_id: "order-123", total: 99.99}
        ),
        build_test_event(:payment_processed,
          stream_id: stream_id,
          correlation_id: command_id,
          causation_id: nil,
          stream_version: 1,
          data: %{status: "success", amount: 99.99}
        ),
        build_test_event(:order_confirmed,
          stream_id: stream_id,
          correlation_id: command_id,
          stream_version: 2,
          data: %{order_id: "order-123"}
        )
      ]

      {:ok, _} = Store.append_events(stream_id, events, -1, store)

      # Assert command produced expected events
      assert_command_event_pattern(
        command_id,
        [
          {:order_placed, %{total: 99.99}},
          {:payment_processed, %{status: "success"}},
          {:order_confirmed, %{}}
        ],
        store,
        stream_id: stream_id
      )
    end

    test "validates saga completion", %{store: store} do
      saga_id = Ecto.UUID.generate()
      stream_id = unique_stream_id("saga")

      # Create saga events
      events = [
        build_test_event(:transfer_initiated,
          stream_id: stream_id,
          aggregate_id: stream_id,
          correlation_id: saga_id,
          stream_version: 0
        ),
        build_test_event(:source_account_debited,
          stream_id: stream_id,
          aggregate_id: stream_id,
          correlation_id: saga_id,
          stream_version: 1
        ),
        build_test_event(:destination_account_credited,
          stream_id: stream_id,
          aggregate_id: stream_id,
          correlation_id: saga_id,
          stream_version: 2
        ),
        build_test_event(:transfer_completed,
          stream_id: stream_id,
          aggregate_id: stream_id,
          correlation_id: saga_id,
          stream_version: 3
        )
      ]

      {:ok, _} = Store.append_events(stream_id, events, -1, store)

      # Assert saga completed successfully
      assert_saga_completion(
        saga_id,
        [
          :transfer_initiated,
          :source_account_debited,
          :destination_account_credited,
          :transfer_completed
        ],
        store
      )
    end
  end

  describe "EventTimeMachine" do
    test "time travel debugging", %{store: store} do
      agent_id = unique_stream_id("time-machine")

      # Create events with specific timestamps
      base_time = ~U[2024-01-15 10:00:00Z]

      events = [
        build_test_event(:agent_started,
          stream_id: agent_id,
          aggregate_id: agent_id,
          stream_version: 0,
          timestamp: base_time,
          data: %{status: :initializing}
        ),
        build_test_event(:agent_configured,
          stream_id: agent_id,
          aggregate_id: agent_id,
          stream_version: 1,
          timestamp: DateTime.add(base_time, 300, :second),
          data: %{status: :configured}
        ),
        build_test_event(:agent_activated,
          stream_id: agent_id,
          aggregate_id: agent_id,
          stream_version: 2,
          timestamp: DateTime.add(base_time, 600, :second),
          data: %{status: :active}
        )
      ]

      {:ok, _} = Store.append_events(agent_id, events, -1, store)

      # Replay to specific time (5 minutes after start)
      state_at_5min =
        replay_to_timestamp(
          DateTime.add(base_time, 300, :second),
          store,
          aggregates: [agent_id]
        )

      assert state_at_5min.aggregates[agent_id].status == :configured

      # Create timeline
      timeline = create_timeline_snapshot(agent_id, store)
      assert length(timeline) == 3

      # Compare states at different times
      comparison =
        compare_states_at_times(
          DateTime.add(base_time, 100, :second),
          DateTime.add(base_time, 700, :second),
          store,
          aggregates: [agent_id]
        )

      changes = comparison.changes.aggregates[agent_id]
      assert changes.status == {:initializing, :active}
    end

    test "creates debug reports", %{store: store} do
      agent_id = unique_stream_id("debug")

      events =
        build_event_sequence(agent_id, [
          :agent_started,
          :agent_configured,
          :agent_message_sent,
          :agent_message_sent,
          :agent_stopped
        ])

      {:ok, _} = Store.append_events(agent_id, events, -1, store)

      # Create debug report
      report = create_debug_report(agent_id, :all, store)

      assert report =~ "Debug Report for Aggregate: #{agent_id}"
      assert report =~ "Total Events: 5"
      assert report =~ "agent_started"
      assert report =~ "agent_stopped"
    end
  end

  describe "Combined utilities" do
    test "comprehensive agent lifecycle test", %{store: store} do
      agent_id = unique_stream_id("lifecycle")
      command_id = Ecto.UUID.generate()

      # Create complete lifecycle events
      events = [
        build_test_event(:agent_start_command,
          stream_id: agent_id,
          aggregate_id: agent_id,
          id: command_id,
          stream_version: 0,
          data: %{model: "claude-3", purpose: "testing"}
        ),
        build_test_event(:agent_started,
          stream_id: agent_id,
          aggregate_id: agent_id,
          causation_id: command_id,
          correlation_id: command_id,
          stream_version: 1,
          data: %{status: :initializing}
        ),
        build_test_event(:agent_configured,
          stream_id: agent_id,
          aggregate_id: agent_id,
          correlation_id: command_id,
          stream_version: 2,
          data: %{status: :configured}
        ),
        build_test_event(:agent_activated,
          stream_id: agent_id,
          aggregate_id: agent_id,
          correlation_id: command_id,
          stream_version: 3,
          data: %{status: :active}
        )
      ]

      {:ok, _} = Store.append_events(agent_id, events, -1, store)

      # 1. Verify event sequence
      assert_event_sequence(
        agent_id,
        [
          :agent_start_command,
          :agent_started,
          :agent_configured,
          :agent_activated
        ],
        store
      )

      # 2. Verify causality
      {:ok, all_events} = Store.read_events(agent_id, 0, :latest, store)
      assert_causality_chain(all_events, allow_gaps: true)

      # 3. Verify aggregate state
      assert_aggregate_state(
        agent_id,
        %{
          status: :active,
          model: "claude-3"
        },
        store
      )

      # 4. Verify command pattern
      assert_command_event_pattern(
        command_id,
        [
          {:agent_started, %{status: :initializing}},
          {:agent_configured, %{}},
          {:agent_activated, %{status: :active}}
        ],
        store,
        stream_id: agent_id
      )

      # 5. Create timeline for debugging
      timeline = create_timeline_snapshot(agent_id, store, fields: [:status, :model])

      # Verify status progression
      statuses = Enum.map(timeline, & &1.state[:status])
      assert statuses == [nil, :initializing, :configured, :active]
    end
  end
end
