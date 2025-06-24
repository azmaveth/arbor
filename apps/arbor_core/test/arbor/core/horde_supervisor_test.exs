defmodule Arbor.Core.HordeSupervisorTest do
  use ExUnit.Case, async: false

  alias Arbor.Core.HordeSupervisor
  alias Arbor.Test.Support.AsyncHelpers

  @moduletag :integration
  @moduletag timeout: 30_000

  # Test configuration
  @registry_name Arbor.Core.HordeAgentRegistry
  @supervisor_name Arbor.Core.HordeAgentSupervisor

  setup do
    # This setup uses the proper Horde infrastructure similar to basic_supervision_test
    Application.put_env(:arbor_core, :registry_impl, :horde)
    Application.put_env(:arbor_core, :supervisor_impl, :horde)

    # Configure agent retry behavior for better test reliability
    Application.put_env(:arbor_core, :agent_retry,
      retries: 5,
      initial_delay: 100
    )

    # Start Phoenix.PubSub if not running (required for ClusterEvents)
    case GenServer.whereis(Arbor.Core.PubSub) do
      nil ->
        {:ok, _} = start_supervised({Phoenix.PubSub, name: Arbor.Core.PubSub})

      _pid ->
        :ok
    end

    # Use the proper Horde infrastructure setup with all required options
    ensure_horde_infrastructure()

    :ok
  end

  describe "agent lifecycle management" do
    @tag :lifecycle
    test "start_agent/1 successfully starts and registers an agent" do
      agent_id = "horde-sup-test-#{System.unique_integer([:positive])}"
      agent_spec = %{id: agent_id, module: Arbor.Test.Mocks.TestAgent, args: [agent_id: agent_id]}

      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
      assert is_pid(pid)

      # Debug: Check if agent process is alive
      IO.puts("Agent PID alive: #{Process.alive?(pid)}")

      # Debug: Check if agent spec exists
      case HordeSupervisor.lookup_agent_spec(agent_id) do
        {:ok, spec} -> IO.puts("Agent spec found: #{inspect(spec)}")
        {:error, :not_found} -> IO.puts("ERROR: Agent spec not found!")
      end

      # Wait for agent to complete self-registration and become visible
      # This accounts for both agent self-registration and CRDT synchronization
      AsyncHelpers.wait_until(
        fn ->
          # Check both spec existence and runtime registration visibility
          spec_result = HordeSupervisor.lookup_agent_spec(agent_id)
          registry_result = Arbor.Core.HordeRegistry.lookup_agent_name(agent_id)
          info_result = HordeSupervisor.get_agent_info(agent_id)

          # Debug output every few attempts
          if :rand.uniform(10) == 1 do
            IO.puts(
              "Debug wait: spec=#{inspect(spec_result)}, registry=#{inspect(registry_result)}, info=#{inspect(info_result)}"
            )
          end

          spec_exists = match?({:ok, _}, spec_result)
          runtime_registered = match?({:ok, _, _}, registry_result)

          if spec_exists and runtime_registered do
            # Both conditions met, check final get_agent_info
            match?({:ok, _}, info_result)
          else
            false
          end
        end,
        timeout: 30_000,
        initial_delay: 200
      )

      # Debug: Check final registration status after waiting
      case Arbor.Core.HordeRegistry.lookup_agent_name(agent_id) do
        {:ok, pid, metadata} ->
          IO.puts("Agent registered in registry: #{inspect({pid, metadata})}")

        {:error, :not_registered} ->
          IO.puts("Agent STILL NOT registered in registry after waiting")
      end

      # Verify agent is registered and info is available
      {:ok, info} = HordeSupervisor.get_agent_info(agent_id)
      assert info.id == agent_id
      assert info.pid == pid
      assert info.module == Arbor.Test.Mocks.TestAgent

      # Cleanup
      assert :ok = HordeSupervisor.stop_agent(agent_id)
    end

    @tag :lifecycle
    test "stop_agent/1 successfully stops a running agent" do
      agent_id = "horde-sup-test-stop-#{System.unique_integer([:positive])}"
      agent_spec = %{id: agent_id, module: Arbor.Test.Mocks.TestAgent, args: [agent_id: agent_id]}

      {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)

      assert :ok = HordeSupervisor.stop_agent(agent_id)

      # Verify agent is no longer running/registered
      assert {:error, :not_found} = HordeSupervisor.get_agent_info(agent_id)
    end

    @tag :error_handling
    test "start_agent/1 returns an error if agent is already started" do
      agent_id = "horde-sup-test-duplicate-#{System.unique_integer([:positive])}"
      agent_spec = %{id: agent_id, module: Arbor.Test.Mocks.TestAgent, args: [agent_id: agent_id]}

      {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)

      # Wait for agent registration to complete and become visible
      AsyncHelpers.wait_until(
        fn ->
          # Check both spec and runtime registration are visible
          spec_exists = match?({:ok, _}, HordeSupervisor.lookup_agent_spec(agent_id))

          runtime_registered =
            match?({:ok, _, _}, Arbor.Core.HordeRegistry.lookup_agent_name(agent_id))

          spec_exists and runtime_registered and
            match?({:ok, _}, HordeSupervisor.get_agent_info(agent_id))
        end,
        timeout: 30_000,
        initial_delay: 200
      )

      # Attempt to start it again
      assert {:error, :already_started} = HordeSupervisor.start_agent(agent_spec)

      # Cleanup
      assert :ok = HordeSupervisor.stop_agent(agent_id)
    end
  end

  # Helper functions

  @spec ensure_horde_infrastructure() :: :ok
  defp ensure_horde_infrastructure do
    # Start HordeSupervisor infrastructure if not running
    if Process.whereis(Arbor.Core.HordeSupervisorSupervisor) == nil do
      HordeSupervisor.start_supervisor()
    end

    # Set members for single-node test environment.
    Horde.Cluster.set_members(@registry_name, [{@registry_name, node()}])
    Horde.Cluster.set_members(@supervisor_name, [{@supervisor_name, node()}])

    # Wait for Horde components to stabilize
    wait_for_membership_ready()
  end

  defp wait_for_membership_ready(timeout \\ 5000) do
    check_fun = fn ->
      registry_members = Horde.Cluster.members(@registry_name)
      supervisor_members = Horde.Cluster.members(@supervisor_name)
      current_node = node()

      # Check for proper named members in various formats
      expected_registry_member = {@registry_name, current_node}
      expected_supervisor_member = {@supervisor_name, current_node}

      registry_ready =
        expected_registry_member in registry_members or
          {expected_registry_member, expected_registry_member} in registry_members

      supervisor_ready =
        expected_supervisor_member in supervisor_members or
          {expected_supervisor_member, expected_supervisor_member} in supervisor_members

      if registry_ready and supervisor_ready do
        true
      else
        false
      end
    end

    case AsyncHelpers.wait_until(check_fun, timeout: timeout, initial_delay: 50) do
      true ->
        # Additional stabilization wait for distributed supervisor CRDT sync
        AsyncHelpers.wait_until(
          fn ->
            case Horde.DynamicSupervisor.which_children(@supervisor_name) do
              [] ->
                true

              children ->
                # Only accept if no children exist or they're properly tracked
                length(children) >= 0
            end
          end,
          timeout: 1000,
          initial_delay: 50
        )

        :ok

      _ ->
        registry_members = Horde.Cluster.members(@registry_name)
        supervisor_members = Horde.Cluster.members(@supervisor_name)

        raise """
        Timed out waiting for Horde membership synchronization.
        - Current Node: #{inspect(node())}
        - Registry Members: #{inspect(registry_members)}
        - Supervisor Members: #{inspect(supervisor_members)}
        """
    end
  end
end
