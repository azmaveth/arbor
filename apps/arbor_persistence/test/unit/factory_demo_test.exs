defmodule Arbor.Persistence.Unit.FactoryDemoTest do
  @moduledoc """
  Demonstration and validation test for the new test data factories.

  This test module demonstrates how to use the factory system and validates
  that it works correctly with the existing test infrastructure without
  breaking compatibility.
  """

  use Arbor.Persistence.FastCase

  # Import the new factories
  import Arbor.Persistence.FactoryHelpers
  import Arbor.Persistence.AgentFactory

  # Import existing test utilities to show compatibility
  import Arbor.Persistence.EventStreamAssertions
  import Arbor.Persistence.AggregateTestHelper
  import Arbor.Persistence.ProjectionTestHelper

  describe "FactoryHelpers compatibility" do
    test "agent lifecycle events work with existing utilities", %{store: store} do
      agent_id = unique_stream_id("agent")

      # Generate agent lifecycle using new factory
      events =
        agent_lifecycle_events(agent_id,
          agent_type: :code_analyzer,
          model: "gpt-4",
          message_count: 3
        )

      # Store events using existing infrastructure
      {:ok, _} = Store.append_events(agent_id, events, -1, store)

      # Validate with existing assertion utilities
      assert_event_sequence(
        agent_id,
        [
          :agent_started,
          :agent_configured,
          :agent_activated,
          :agent_message_sent,
          :agent_message_sent,
          :agent_message_sent,
          :agent_stopped
        ],
        store
      )

      # Test aggregate state reconstruction
      final_state = replay_to_aggregate(agent_id, store)
      assert final_state.status == :stopped
      assert Map.get(final_state, :tasks_completed) == 3

      # Verify timeline tracking
      assert_stream_version(agent_id, 6, store)
      assert_timestamp_ordering(agent_id, store)
    end

    test "session and command events integrate properly", %{store: store} do
      session_id = unique_stream_id("session")

      # Create session using factory
      session_event =
        session_created_event(session_id,
          user_id: "developer@example.com",
          purpose: "AI-assisted Elixir development",
          max_agents: 5
        )

      # Create command using factory
      command_event =
        command_received_event(:spawn_agent,
          command_id: "cmd_123",
          agent_type: :llm,
          model: "claude-3.5-sonnet",
          session_id: session_id
        )

      # Store events
      {:ok, _} = Store.append_events(session_id, [session_event], -1, store)
      {:ok, _} = Store.append_events("gateway", [command_event], -1, store)

      # Validate using existing tools
      assert_event_sequence(session_id, [:session_created], store)
      assert_event_sequence("gateway", [:command_received], store)

      # Check event data integrity
      {:ok, session_events} = Store.read_events(session_id, 0, :latest, store)
      session_data = hd(session_events).data

      assert session_data.session_id == session_id
      assert session_data.user_id == "developer@example.com"
      assert session_data.max_agents == 5
    end
  end

  describe "AgentFactory advanced scenarios" do
    test "coordinator with workers scenario", %{store: store} do
      # Create realistic multi-agent scenario
      {coordinator, workers} =
        create_coordinator_with_workers(3,
          worker_types: [:code_analyzer, :test_generator, :documentation_writer],
          task_distribution: :round_robin
        )

      # Store all agent events
      all_agents = [coordinator | workers]

      for agent <- all_agents do
        {:ok, _} = Store.append_events(agent.agent_id, agent.events, -1, store)
      end

      # Validate coordinator setup
      coordinator_state = replay_to_aggregate(coordinator.agent_id, store)
      # Lifecycle includes stop event
      assert coordinator_state.status == :stopped
      assert coordinator_state.agent_type == :coordinator

      # Validate worker relationships
      for worker <- workers do
        worker_state = replay_to_aggregate(worker.agent_id, store)
        # Lifecycle includes stop event
        assert worker_state.status == :stopped
        assert worker_state.parent_id == coordinator.agent_id
        assert worker_state.session_id == coordinator.session_id
      end

      # Check coordination events
      assert_event_sequence(
        coordinator.agent_id,
        [
          :agent_started,
          :agent_configured,
          :agent_activated,
          :agent_message_sent,
          :agent_message_sent,
          :agent_stopped,
          :workers_assigned,
          :coordination_started
        ],
        store,
        strict: false
      )
    end

    test "agent hierarchy scenario", %{store: store} do
      # Create hierarchical agent structure
      agents =
        create_agent_hierarchy("root-coordinator",
          depth: 2,
          fanout: 2,
          capability_inheritance: true
        )

      # Store all agent events
      for agent <- agents do
        {:ok, _} = Store.append_events(agent.agent_id, agent.events, -1, store)
      end

      # Validate hierarchy structure
      root_agent = List.first(agents)
      root_state = replay_to_aggregate(root_agent.agent_id, store)

      assert root_state.agent_type == :coordinator
      assert Map.get(root_state, :priority, :normal) == :urgent

      # Validate child relationships
      child_agents = Enum.drop(agents, 1)

      for child <- child_agents do
        child_state = replay_to_aggregate(child.agent_id, store)
        assert child_state.parent_id != nil
        assert child_state.session_id == root_state.session_id
      end

      # Check that hierarchy events were created
      assert_event_sequence(
        root_agent.agent_id,
        [
          :hierarchy_established
        ],
        store,
        strict: false
      )
    end

    test "failure scenario generation", %{store: store} do
      # Create agents for failure testing
      agents = [
        create_agent("test-agent-1", :llm),
        create_agent("test-agent-2", :code_analyzer)
      ]

      # Generate failure scenario
      failure_events =
        create_failure_scenario(agents, :crash,
          failure_time: ~U[2024-01-15 10:00:00Z],
          recovery_time: ~U[2024-01-15 10:01:00Z]
        )

      # Store failure events
      {:ok, _} = Store.append_events("test-agent-1", failure_events, -1, store)

      # Validate failure events
      assert length(failure_events) > 0

      # Check that failure events have proper structure
      for event <- failure_events do
        assert event.type in [:agent_crashed, :agent_recovery_started]
        assert event.aggregate_id == "test-agent-1"
        assert is_map(event.data)
      end
    end
  end

  describe "Performance and compatibility" do
    test "factory performance is acceptable", %{store: store} do
      # Measure time to create multiple agents
      start_time = System.monotonic_time(:millisecond)

      agents =
        1..10
        |> Enum.map(fn i ->
          create_agent("perf-agent-#{i}", :llm,
            model: "claude-3-haiku",
            message_count: 1
          )
        end)

      end_time = System.monotonic_time(:millisecond)
      creation_time = end_time - start_time

      # Should be fast enough for test usage (< 100ms for 10 agents)
      assert creation_time < 100, "Factory creation took #{creation_time}ms, expected < 100ms"

      # Verify all agents created successfully
      assert length(agents) == 10

      for agent <- agents do
        assert agent.agent_id != nil
        assert agent.agent_type == :llm
        assert agent.model == "claude-3-haiku"
        assert is_list(agent.events)
        # lifecycle + 1 message
        assert length(agent.events) == 6
      end
    end

    test "existing build_test_event still works unchanged", %{store: store} do
      # Verify that original helper is not broken
      stream_id = unique_stream_id("test")

      # Use original build_test_event (not factory extension)
      original_event =
        build_test_event(:test_event,
          stream_id: stream_id,
          data: %{test: "original_functionality"}
        )

      # Store and validate
      {:ok, _} = Store.append_events(stream_id, [original_event], -1, store)

      {:ok, events} = Store.read_events(stream_id, 0, :latest, store)
      stored_event = hd(events)

      assert stored_event.type == :test_event
      assert stored_event.data.test == "original_functionality"
      assert stored_event.stream_id == stream_id
    end

    test "factory events are properly structured", %{store: store} do
      agent_id = unique_stream_id("structure_test")

      # Create events using factory
      events = agent_lifecycle_events(agent_id)

      # Validate event structure compliance
      for {event, index} <- Enum.with_index(events) do
        # Check required fields
        assert event.id != nil
        assert event.type != nil
        assert event.aggregate_id == agent_id
        assert event.stream_id == agent_id
        assert event.stream_version == index
        assert is_map(event.data)
        assert event.timestamp != nil

        # Check correlation chain
        if index > 0 do
          assert event.correlation_id != nil
          assert event.causation_id != nil
        end

        # Check data structure
        assert is_atom(event.type)
        assert event.aggregate_type == :agent
        assert event.version =~ ~r/\d+\.\d+\.\d+/
      end
    end
  end

  describe "Integration with existing event sourcing utilities" do
    test "factories work with EventPatternMatcher", %{store: store} do
      agent_id = unique_stream_id("pattern_test")
      command_id = Ecto.UUID.generate()

      # Create lifecycle events with correlation
      events =
        agent_lifecycle_events(agent_id,
          correlation_id: command_id,
          message_count: 1
        )

      {:ok, _} = Store.append_events(agent_id, events, -1, store)

      # Use EventPatternMatcher to validate patterns
      import Arbor.Persistence.EventPatternMatcher

      assert_command_event_pattern(
        command_id,
        [
          {:agent_started, %{}},
          {:agent_configured, %{}},
          {:agent_activated, %{status: :active}}
        ],
        store,
        stream_id: agent_id
      )
    end

    test "factories work with EventTimeMachine", %{store: store} do
      agent_id = unique_stream_id("time_test")

      # Create events with specific timestamps
      base_time = ~U[2024-01-15 10:00:00Z]

      events = [
        agent_started_event(agent_id) |> Map.put(:timestamp, base_time),
        agent_configured_event(agent_id)
        |> Map.put(:timestamp, DateTime.add(base_time, 60, :second)),
        agent_activated_event(agent_id)
        |> Map.put(:timestamp, DateTime.add(base_time, 120, :second))
      ]

      # Set proper stream versions
      events =
        events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} ->
          %{event | stream_version: index}
        end)

      {:ok, _} = Store.append_events(agent_id, events, -1, store)

      # Use EventTimeMachine to replay to specific time
      import Arbor.Persistence.EventTimeMachine

      state_at_61s =
        replay_to_timestamp(
          DateTime.add(base_time, 61, :second),
          store,
          aggregates: [agent_id]
        )

      aggregate_state = Map.get(state_at_61s.aggregates, agent_id, %{})
      # The agent should be configured by 61 seconds (after started+configured events)
      assert Map.get(aggregate_state, :configured, false) == true
    end
  end
end
