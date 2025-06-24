defmodule Arbor.Core.LocationTransparencyTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.Core.{Gateway, ClusterRegistry, ClusterSupervisor}
  alias Arbor.Core.Sessions.Manager, as: SessionManager

  setup_all do
    # Ensure Phoenix.PubSub is running
    case GenServer.whereis(Arbor.Core.PubSub) do
      nil ->
        {:ok, _} = start_supervised({Phoenix.PubSub, name: Arbor.Core.PubSub})

      _pid ->
        :ok
    end

    # Ensure we're using the distributed implementations (mock for tests)
    Application.put_env(:arbor_core, :registry_impl, :mock)
    Application.put_env(:arbor_core, :supervisor_impl, :mock)

    # Stop any existing instances first
    case Process.whereis(Arbor.Test.Mocks.LocalSupervisor) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 100)
    end

    case Process.whereis(Arbor.Test.Mocks.LocalClusterRegistry) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 100)
    end

    case Process.whereis(Arbor.Core.Registry) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :shutdown)
        # Allow ETS cleanup
        Process.sleep(10)
    end

    # Start fresh instances
    {:ok, _registry} = Registry.start_link(keys: :unique, name: Arbor.Core.Registry)
    {:ok, _mock_registry} = Arbor.Test.Mocks.LocalClusterRegistry.start_link()
    {:ok, _mock_supervisor} = Arbor.Test.Mocks.LocalSupervisor.start_link()

    # Ensure Gateway is running
    case GenServer.whereis(Arbor.Core.Gateway) do
      nil ->
        {:ok, _gateway} = start_supervised(Arbor.Core.Gateway)

      _pid ->
        :ok
    end

    # Ensure TaskSupervisor is running for async execution
    case Process.whereis(Arbor.TaskSupervisor) do
      nil ->
        {:ok, _} = start_supervised({Task.Supervisor, name: Arbor.TaskSupervisor})

      _pid ->
        :ok
    end

    # Ensure SessionRegistry is running
    case Process.whereis(Arbor.Core.Sessions.SessionRegistry) do
      nil ->
        {:ok, _} =
          start_supervised({Registry, keys: :unique, name: Arbor.Core.Sessions.SessionRegistry})

      _pid ->
        :ok
    end

    # Ensure Sessions.Manager is running
    case GenServer.whereis(Arbor.Core.Sessions.Manager) do
      nil ->
        {:ok, _} = start_supervised(Arbor.Core.Sessions.Manager)

      _pid ->
        :ok
    end

    on_exit(fn ->
      # Reset configuration first
      Application.put_env(:arbor_core, :registry_impl, :auto)
      Application.put_env(:arbor_core, :supervisor_impl, :auto)
    end)

    :ok
  end

  setup do
    # Clean state before each test
    if Process.whereis(Arbor.Test.Mocks.LocalClusterRegistry) do
      Arbor.Test.Mocks.LocalClusterRegistry.clear()
    end

    if Process.whereis(Arbor.Test.Mocks.LocalSupervisor) do
      Arbor.Test.Mocks.LocalSupervisor.clear()
    end

    :ok
  end

  describe "Gateway location transparency" do
    test "can discover agents regardless of location" do
      # Start an agent through the cluster supervisor
      agent_spec = %{
        id: "test_agent_001",
        module: Arbor.Test.Mocks.TestAgent,
        args: [name: "test_agent"],
        metadata: %{
          type: :tool_executor,
          capabilities: ["code_analysis", "test_generation"]
        }
      }

      {:ok, agent_pid} = ClusterSupervisor.start_agent(agent_spec)

      # Agent should be discoverable via registry
      assert {:ok, ^agent_pid, metadata} = ClusterRegistry.lookup_agent("test_agent_001")
      assert metadata.type == :tool_executor

      # Gateway should be able to query agents
      {:ok, session_info} = Gateway.create_session(metadata: %{client_type: :test})
      session_id = session_info.session_id

      # Subscribe to execution events to get the result
      Gateway.subscribe_session(session_id)

      # This should use the distributed registry
      {:async, execution_id} =
        Gateway.execute(session_id, "query_agents", %{
          filter: "type:tool_executor"
        })

      # Wait for the execution result
      result =
        receive do
          {:execution_event, %{execution_id: ^execution_id, status: :completed, result: result}} ->
            result
        after
          1000 ->
            flunk("Timeout waiting for execution result")
        end

      # Should find our agent
      assert result.agents

      assert Enum.any?(result.agents, fn agent ->
               agent.id == "test_agent_001"
             end)

      # Cleanup
      :ok = ClusterSupervisor.stop_agent("test_agent_001")
      :ok = Gateway.end_session(session_id)
    end

    test "sessions can manage distributed agents" do
      # Create a session
      session_params = %{
        user_id: "test_user",
        purpose: "Location transparency test",
        context: %{client_type: :test}
      }

      {:ok, session_struct} = SessionManager.create_session(session_params, SessionManager)
      session_id = session_struct.id

      # Get the session process
      {:ok, session_pid, _metadata} = SessionManager.get_session(session_id)

      # Start an agent on the cluster
      agent_spec = %{
        id: "session_agent_001",
        module: Arbor.Test.Mocks.TestAgent,
        args: [name: "session_agent"],
        metadata: %{
          type: :coordinator,
          session_id: session_id
        }
      }

      {:ok, agent_pid} = ClusterSupervisor.start_agent(agent_spec)

      # Register the agent with the session (sessions track agent IDs, not PIDs)
      # The session will look up the agent when needed via ClusterRegistry
      :ok = Arbor.Core.Sessions.Session.add_agent(session_pid, "session_agent_001")

      # Get session info - should include the agent
      {:ok, info} = SessionManager.get_session_info(session_id)
      assert "session_agent_001" in info.active_agents

      # Agent should be findable even if on different node
      assert {:ok, ^agent_pid, _metadata} = ClusterRegistry.lookup_agent("session_agent_001")

      # Cleanup
      :ok = SessionManager.end_session(session_id)
      :ok = ClusterSupervisor.stop_agent("session_agent_001")
    end

    test "agent failover maintains location transparency" do
      # Start an agent
      agent_spec = %{
        id: "failover_agent_001",
        module: Arbor.Test.Mocks.TestAgent,
        args: [name: "failover_agent"],
        restart_strategy: :permanent,
        metadata: %{
          type: :llm,
          important_state: "preserved"
        }
      }

      {:ok, original_pid} = ClusterSupervisor.start_agent(agent_spec)

      # Verify agent is registered and discoverable
      assert {:ok, ^original_pid, metadata} = ClusterRegistry.lookup_agent("failover_agent_001")
      assert metadata.important_state == "preserved"

      # Simulate failover by restarting the agent (this tests location transparency)
      # In a real cluster, this would happen automatically
      {:ok, new_pid} = ClusterSupervisor.restart_agent("failover_agent_001")
      assert new_pid != original_pid

      # Agent should still be findable after restart (location transparency)
      assert {:ok, current_pid, metadata} = ClusterRegistry.lookup_agent("failover_agent_001")
      assert current_pid == new_pid
      assert metadata.important_state == "preserved"

      # Cleanup
      :ok = ClusterSupervisor.stop_agent("failover_agent_001")
    end
  end

  describe "distributed agent groups" do
    test "can query agents by group across cluster" do
      # Start multiple agents in a group
      agent_specs = [
        %{
          id: "analyzer_001",
          module: Arbor.Test.Mocks.TestAgent,
          args: [name: "analyzer1"],
          metadata: %{type: :analyzer}
        },
        %{
          id: "analyzer_002",
          module: Arbor.Test.Mocks.TestAgent,
          args: [name: "analyzer2"],
          metadata: %{type: :analyzer}
        },
        %{
          id: "executor_001",
          module: Arbor.Test.Mocks.TestAgent,
          args: [name: "executor1"],
          metadata: %{type: :executor}
        }
      ]

      # Start all agents
      pids =
        for spec <- agent_specs do
          {:ok, pid} = ClusterSupervisor.start_agent(spec)

          # Register in analyzer group if applicable
          if spec.metadata.type == :analyzer do
            :ok = ClusterRegistry.register_group("analyzers", spec.id)
          end

          {spec.id, pid}
        end

      # Query analyzer group
      {:ok, analyzer_members} = ClusterRegistry.list_group_members("analyzers")
      assert length(analyzer_members) == 2
      assert "analyzer_001" in analyzer_members
      assert "analyzer_002" in analyzer_members

      # Pattern matching for agents
      {:ok, all_agents} = ClusterRegistry.list_by_pattern("*_00*")
      assert length(all_agents) == 3

      # Cleanup
      for {agent_id, _pid} <- pids do
        :ok = ClusterSupervisor.stop_agent(agent_id)
      end
    end
  end
end
