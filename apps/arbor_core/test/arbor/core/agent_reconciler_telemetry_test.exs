defmodule Arbor.Core.AgentReconcilerTelemetryTest do
  @moduledoc """
  Tests for comprehensive telemetry emitted by the AgentReconciler.

  Validates that all reconciliation events are properly instrumented
  for observability and monitoring.
  """

  use Arbor.Test.Support.IntegrationCase

  alias Arbor.Core.{AgentReconciler, HordeSupervisor}

  describe "reconciliation telemetry" do
    test "emits comprehensive telemetry events during reconciliation" do
      # Capture all reconciliation telemetry events
      test_pid = self()
      handler_id = :reconciler_telemetry_test

      events_to_track = [
        [:arbor, :reconciliation, :start],
        [:arbor, :reconciliation, :lookup_performance],
        [:arbor, :reconciliation, :agent_discovery],
        [:arbor, :reconciliation, :complete],
        [:arbor, :reconciliation, :agent_restart_success],
        [:arbor, :reconciliation, :agent_cleanup_success]
      ]

      :telemetry.attach_many(
        handler_id,
        events_to_track,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      # Create a scenario with missing agents
      agent_id = "telemetry-test-agent-#{System.unique_integer([:positive])}"

      # Start an agent
      agent_spec = %{
        id: agent_id,
        module: TelemetryTestAgent,
        args: [agent_id: agent_id],
        restart_strategy: :permanent
      }

      assert {:ok, agent_pid} = HordeSupervisor.start_agent(agent_spec)

      # Wait for agent to be registered and ready
      AsyncHelpers.wait_for_agent_ready(agent_id, timeout: 2000)

      # Kill the agent to create a missing agent scenario using proper supervisor termination
      Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, agent_pid)

      # Wait for process to actually die
      AsyncHelpers.wait_until(
        fn ->
          not Process.alive?(agent_pid)
        end,
        timeout: 2000,
        initial_delay: 25
      )

      # Force reconciliation to trigger telemetry
      AgentReconciler.force_reconcile()

      # Wait for reconciliation to complete and agent to be restarted
      AsyncHelpers.wait_until(
        fn ->
          case HordeSupervisor.get_agent_info(agent_id) do
            {:ok, agent_info} -> Process.alive?(agent_info.pid)
            _ -> false
          end
        end,
        timeout: 3000,
        initial_delay: 100
      )

      # Verify telemetry events were emitted
      assert_received {:telemetry, [:arbor, :reconciliation, :start], start_measurements,
                       start_metadata}

      assert Map.has_key?(start_measurements, :start_time)
      assert start_metadata.node == node()
      assert start_metadata.reconciler == AgentReconciler

      assert_received {:telemetry, [:arbor, :reconciliation, :lookup_performance],
                       perf_measurements, _perf_metadata}

      assert Map.has_key?(perf_measurements, :spec_lookup_duration_ms)
      assert Map.has_key?(perf_measurements, :supervisor_lookup_duration_ms)
      assert Map.has_key?(perf_measurements, :specs_found)
      assert Map.has_key?(perf_measurements, :running_processes)

      assert_received {:telemetry, [:arbor, :reconciliation, :agent_discovery],
                       discovery_measurements, discovery_metadata}

      assert Map.has_key?(discovery_measurements, :total_specs)
      assert Map.has_key?(discovery_measurements, :total_running)
      assert Map.has_key?(discovery_measurements, :missing_count)
      assert Map.has_key?(discovery_measurements, :orphaned_count)
      # Our killed agent
      assert discovery_measurements.missing_count >= 1
      assert is_list(discovery_metadata.missing_agents)

      assert_received {:telemetry, [:arbor, :reconciliation, :agent_restart_success],
                       restart_measurements, restart_metadata}

      assert Map.has_key?(restart_measurements, :duration_ms)
      assert restart_metadata.agent_id == agent_id
      assert restart_metadata.restart_strategy == :permanent
      assert restart_metadata.module == TelemetryTestAgent

      assert_received {:telemetry, [:arbor, :reconciliation, :complete], complete_measurements,
                       complete_metadata}

      # Verify comprehensive completion metrics
      assert Map.has_key?(complete_measurements, :missing_agents_restarted)
      assert Map.has_key?(complete_measurements, :orphaned_agents_cleaned)
      assert Map.has_key?(complete_measurements, :duration_ms)
      assert Map.has_key?(complete_measurements, :reconciliation_efficiency)
      assert Map.has_key?(complete_measurements, :system_health_score)
      assert Map.has_key?(complete_measurements, :restart_errors_count)
      assert Map.has_key?(complete_measurements, :cleanup_errors_count)

      # Verify health metrics are reasonable
      assert complete_measurements.reconciliation_efficiency >= 0.0
      assert complete_measurements.reconciliation_efficiency <= 1.0
      assert complete_measurements.system_health_score >= 0.0
      assert complete_measurements.system_health_score <= 1.0

      assert complete_metadata.node == node()
      assert complete_metadata.reconciler == AgentReconciler

      # Cleanup
      :telemetry.detach(handler_id)
      HordeSupervisor.stop_agent(agent_id)
    end

    test "emits error telemetry for failed operations" do
      test_pid = self()
      handler_id = :error_telemetry_test

      :telemetry.attach(
        handler_id,
        [:arbor, :reconciliation, :agent_restart_failed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      # Create an agent spec that will cause issues (module fails to init)
      agent_id = "error-test-agent-#{System.unique_integer([:positive])}"
      spec_key = {:agent_spec, agent_id}

      bad_spec = %{
        module: FailingTestAgent,
        args: [],
        restart_strategy: :permanent,
        metadata: %{},
        created_at: System.system_time(:millisecond)
      }

      # Manually register the spec, as HordeSupervisor would reject it
      Horde.Registry.register(@registry_name, spec_key, bad_spec)

      # Force reconciliation which should try to restart the agent and fail
      AgentReconciler.force_reconcile()

      # Wait for reconciliation to process the spec
      # We can't check for the telemetry message here because receive consumes it
      # Instead, just wait a bit for reconciliation to complete
      Process.sleep(500)

      # We should receive error telemetry for the failed restart
      assert_received {:telemetry, [:arbor, :reconciliation, :agent_restart_failed],
                       _measurements, metadata}

      assert metadata.agent_id == agent_id
      assert metadata.restart_strategy == :permanent
      assert metadata.module == FailingTestAgent

      # Cleanup
      :telemetry.detach(handler_id)
      Horde.Registry.unregister(@registry_name, spec_key)
    end

    test "tracks performance metrics accurately" do
      # Start several agents to create meaningful performance data
      agent_count = 5
      agent_prefix = "perf-test-agent"
      test_id = System.unique_integer([:positive])

      agent_ids =
        for i <- 1..agent_count do
          agent_id = "#{agent_prefix}-#{test_id}-#{i}"

          agent_spec = %{
            id: agent_id,
            module: TelemetryTestAgent,
            args: [agent_id: agent_id, index: i],
            restart_strategy: :permanent
          }

          assert {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)
          agent_id
        end

      # Wait for all agents to be registered and stable
      AsyncHelpers.wait_until(
        fn ->
          Enum.all?(agent_ids, fn agent_id ->
            case HordeSupervisor.get_agent_info(agent_id) do
              {:ok, agent_info} -> Process.alive?(agent_info.pid)
              _ -> false
            end
          end)
        end,
        timeout: 3000,
        initial_delay: 100
      )

      # Capture performance telemetry
      test_pid = self()
      handler_id = :perf_telemetry_test

      :telemetry.attach(
        handler_id,
        [:arbor, :reconciliation, :lookup_performance],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      # Force reconciliation
      AgentReconciler.force_reconcile()

      # Wait for reconciliation to complete
      # We can't check for the telemetry message here because receive consumes it
      # Instead, just wait a bit for reconciliation to complete
      Process.sleep(300)

      # Verify performance metrics
      assert_received {:telemetry, [:arbor, :reconciliation, :lookup_performance], measurements,
                       _metadata}

      # Performance metrics should be reasonable
      assert measurements.spec_lookup_duration_ms >= 0
      assert measurements.supervisor_lookup_duration_ms >= 0
      assert measurements.specs_found >= agent_count
      assert measurements.running_processes >= agent_count

      # Performance should be fast for small numbers of agents
      # Should be under 1 second
      assert measurements.spec_lookup_duration_ms < 1000
      assert measurements.supervisor_lookup_duration_ms < 1000

      # Cleanup
      :telemetry.detach(handler_id)

      for agent_id <- agent_ids do
        HordeSupervisor.stop_agent(agent_id)
      end
    end
  end
end

# Test agent for telemetry testing
defmodule TelemetryTestAgent do
  use GenServer

  alias Arbor.Core.HordeRegistry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @spec init(keyword()) :: {:ok, map()}
  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      index: Keyword.get(args, :index, 0),
      started_at: System.system_time(:millisecond)
    }

    # Self-register in HordeRegistry if agent_id is provided
    if agent_id do
      runtime_metadata = %{started_at: state.started_at}

      case HordeRegistry.register_agent_name(agent_id, self(), runtime_metadata) do
        {:ok, _} ->
          :ok

        error ->
          IO.puts("Agent registration failed: #{inspect(error)}")
      end
    end

    {:ok, state}
  end

  @spec terminate(any(), map()) :: :ok
  def terminate(_reason, state) do
    if state.agent_id do
      HordeRegistry.unregister_agent_name(state.agent_id)
    end

    :ok
  end
end

defmodule FailingTestAgent do
  use GenServer

  def start_link(_args) do
    GenServer.start_link(__MODULE__, :ok)
  end

  def init(:ok) do
    {:stop, :init_failed}
  end
end
