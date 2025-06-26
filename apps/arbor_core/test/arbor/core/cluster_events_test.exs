defmodule Arbor.Core.ClusterEventsTest do
  @moduledoc """
  Tests for cluster-wide event broadcasting using Phoenix.PubSub.

  Validates that agent lifecycle events and reconciliation events
  are properly broadcast across the cluster.
  """

  use Arbor.Test.Support.IntegrationCase

  alias Arbor.Core.{AgentReconciler, ClusterEvents, HordeSupervisor}

  @moduletag :slow

  describe "agent lifecycle events" do
    test "broadcasts agent_started events when agents are created" do
      agent_id = "test-cluster-events-start-#{System.unique_integer([:positive])}"

      # Subscribe to agent events
      :ok = ClusterEvents.subscribe(:agent_events)

      # Start an agent
      agent_spec = %{
        id: agent_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }

      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      # Verify we receive the cluster event
      assert_receive {:cluster_event, :agent_started, event_data}, 1000

      assert event_data.agent_id == agent_id
      assert event_data.pid == pid
      assert event_data.node == node()
      assert event_data.module == Arbor.Test.Mocks.TestAgent
      assert event_data.restart_strategy == :permanent
      assert is_integer(event_data.timestamp)
      assert event_data.event_type == :agent_started

      # Cleanup
      HordeSupervisor.stop_agent(agent_id)
      ClusterEvents.unsubscribe(:agent_events)
    end

    test "broadcasts agent_stopped events when agents are stopped" do
      agent_id = "test-cluster-events-stop-#{System.unique_integer([:positive])}"

      # Subscribe to agent events first
      :ok = ClusterEvents.subscribe(:agent_events)

      # Start an agent using the proper HordeSupervisor API
      agent_spec = %{
        id: agent_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :temporary
      }

      {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      # Wait for start event and clear it
      assert_receive {:cluster_event, :agent_started, _}, 2000

      # Wait for agent to complete registration
      AsyncHelpers.assert_eventually(
        fn ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, agent_info} when agent_info.pid == pid ->
              IO.puts("Agent registration successful: #{inspect(agent_info)}")
              {:ok, agent_info}

            result ->
              IO.puts("Agent registration check: #{inspect(result)}")
              :retry
          end
        end,
        "Agent should be fully registered",
        max_attempts: 20
      )

      # Now stop the agent
      :ok = HordeSupervisor.stop_agent(agent_id)

      # Verify we receive the cluster event
      assert_receive {:cluster_event, :agent_stopped, event_data}, 1000

      assert event_data.agent_id == agent_id
      assert event_data.pid == pid
      assert event_data.node == node()
      assert is_integer(event_data.timestamp)
      assert event_data.event_type == :agent_stopped

      # Cleanup
      ClusterEvents.unsubscribe(:agent_events)
    end

    test "broadcasts agent_restarted events during reconciliation" do
      agent_id = "test-cluster-events-restart-#{System.unique_integer([:positive])}"

      # Subscribe to agent events
      :ok = ClusterEvents.subscribe(:agent_events)

      # Start an agent
      agent_spec = %{
        id: agent_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }

      assert {:ok, original_pid} = HordeSupervisor.start_agent(agent_spec)

      # Clear the start event
      assert_receive {:cluster_event, :agent_started, _}, 1000

      # Kill the agent to trigger reconciliation restart
      # Use proper supervisor termination instead of Process.exit
      # DON'T unregister from registry - let reconciler detect missing agent
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, original_pid)

      # Wait for process to actually die
      AsyncHelpers.wait_until(fn -> not Process.alive?(original_pid) end,
        timeout: 2000,
        initial_delay: 25
      )

      # Force reconciliation
      AgentReconciler.force_reconcile()

      # Verify we receive the restart event
      assert_receive {:cluster_event, :agent_restarted, event_data}, 2000

      assert event_data.agent_id == agent_id
      assert event_data.module == Arbor.Test.Mocks.TestAgent
      assert event_data.restart_strategy == :permanent
      assert is_integer(event_data.restart_duration_ms)
      assert is_integer(event_data.memory_usage)
      assert event_data.event_type == :agent_restarted

      # Cleanup
      HordeSupervisor.stop_agent(agent_id)
      ClusterEvents.unsubscribe(:agent_events)
    end

    test "supports agent-specific event subscriptions" do
      agent1_id = "test-specific-events-1-#{System.unique_integer([:positive])}"
      agent2_id = "test-specific-events-2-#{System.unique_integer([:positive])}"

      # Subscribe to events for agent1 only
      :ok = ClusterEvents.subscribe(:agent_events, agent_id: agent1_id)

      # Start both agents
      agent1_spec = %{
        id: agent1_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [agent_id: agent1_id],
        restart_strategy: :permanent
      }

      agent2_spec = %{
        id: agent2_id,
        module: Arbor.Test.Mocks.TestAgent,
        args: [agent_id: agent2_id],
        restart_strategy: :permanent
      }

      {:ok, _pid1} = HordeSupervisor.start_agent(agent1_spec)
      {:ok, _pid2} = HordeSupervisor.start_agent(agent2_spec)

      # Should only receive events for agent1
      assert_receive {:cluster_event, :agent_started, event_data}, 1000
      assert event_data.agent_id == agent1_id

      # Should not receive events for agent2
      refute_receive {:cluster_event, :agent_started, %{agent_id: ^agent2_id}}, 500

      # Cleanup
      HordeSupervisor.stop_agent(agent1_id)
      HordeSupervisor.stop_agent(agent2_id)
      ClusterEvents.unsubscribe(:agent_events, agent_id: agent1_id)
    end
  end

  describe "reconciliation events" do
    test "broadcasts reconciliation_started and reconciliation_completed events" do
      # Subscribe to reconciliation events
      :ok = ClusterEvents.subscribe(:reconciliation_events)

      # Force a reconciliation
      AgentReconciler.force_reconcile()

      # Verify we receive both events
      assert_receive {:cluster_event, :reconciliation_started, start_event}, 1000
      assert start_event.reconciler == AgentReconciler
      assert start_event.event_type == :reconciliation_started

      assert_receive {:cluster_event, :reconciliation_completed, complete_event}, 2000
      assert complete_event.reconciler == AgentReconciler
      assert complete_event.event_type == :reconciliation_completed
      assert is_integer(complete_event.duration_ms)
      assert is_number(complete_event.reconciliation_efficiency)

      # Cleanup
      ClusterEvents.unsubscribe(:reconciliation_events)
    end
  end

  describe "cluster event utilities" do
    test "get_stats returns cluster information" do
      stats = ClusterEvents.get_stats()

      assert is_map(stats.active_topics)
      assert stats.node == node()
      assert is_binary(stats.cluster_id)
      assert stats.pubsub_name == Arbor.Core.PubSub
    end

    test "subscriber_count returns counts for topics" do
      # Note: Phoenix.PubSub doesn't expose subscriber counts directly
      # so this should return 0 for now
      assert ClusterEvents.subscriber_count(:agent_events) == 0
      assert ClusterEvents.subscriber_count(:cluster_events) == 0
      assert ClusterEvents.subscriber_count(:reconciliation_events) == 0
    end

    test "list_active_topics returns topic information" do
      topics = ClusterEvents.list_active_topics()

      assert Map.has_key?(topics, "agent_events")
      assert Map.has_key?(topics, "cluster_events")
      assert Map.has_key?(topics, "reconciliation_events")
    end
  end

  describe "event telemetry" do
    test "cluster event broadcasts emit telemetry" do
      # Capture telemetry events
      test_pid = self()
      handler_id = :cluster_events_telemetry_test

      :telemetry.attach(
        handler_id,
        [:arbor, :cluster_events, :broadcast],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      # Broadcast an event
      ClusterEvents.broadcast(:agent_started, %{
        agent_id: "test-telemetry-agent",
        pid: self(),
        module: Arbor.Test.Mocks.TestAgent
      })

      # Verify telemetry was emitted
      assert_receive {:telemetry, [:arbor, :cluster_events, :broadcast], measurements, metadata}
      assert measurements.event_count == 1
      assert metadata.event_type == :agent_started
      assert metadata.agent_id == "test-telemetry-agent"
      assert metadata.node == node()

      # Cleanup
      :telemetry.detach(handler_id)
    end
  end
end
