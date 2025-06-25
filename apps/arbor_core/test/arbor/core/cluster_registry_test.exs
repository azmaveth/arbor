defmodule Arbor.Core.ClusterRegistryTest do
  @moduledoc """
  Unit tests for distributed agent registry logic using local mocks.

  These tests use MOCK implementations to test registry logic without
  requiring actual distributed clustering. The real Horde-based
  implementation will be tested in integration tests.
  """

  use ExUnit.Case, async: true

  alias Arbor.Test.Mocks.LocalClusterRegistry

  @moduletag :integration

  setup do
    # MOCK: Use local registry for unit testing
    # Replace with Horde for distributed operation

    # Stop any existing agent
    case Process.whereis(LocalClusterRegistry) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    # Start fresh agent for this test
    {:ok, _pid} = LocalClusterRegistry.start_link([])

    # Clear any existing state
    LocalClusterRegistry.clear()

    {:ok, state} = LocalClusterRegistry.init([])
    %{registry_state: state}
  end

  describe "agent registration" do
    test "registers agent with unique ID", %{registry_state: state} do
      agent_id = "agent-123"
      metadata = %{type: :llm_agent, capabilities: [:chat, :analysis]}

      # MOCK: Use local registry for unit testing
      assert :ok = LocalClusterRegistry.register_name({:agent, agent_id}, self(), metadata, state)

      assert {:ok, {pid, ^metadata}} = LocalClusterRegistry.lookup_name({:agent, agent_id}, state)
      assert pid == self()
    end

    test "prevents duplicate agent registration", %{registry_state: state} do
      agent_id = "agent-123"
      metadata = %{type: :worker_agent}

      # MOCK: Use local registry for unit testing
      :ok = LocalClusterRegistry.register_name({:agent, agent_id}, self(), metadata, state)

      # Attempting to register same agent ID should fail
      assert {:error, :name_taken} =
               LocalClusterRegistry.register_name({:agent, agent_id}, self(), metadata, state)
    end

    test "allows different agents with different IDs", %{registry_state: state} do
      metadata = %{type: :llm_agent}

      # MOCK: Use local registry for unit testing
      assert :ok =
               LocalClusterRegistry.register_name({:agent, "agent-1"}, self(), metadata, state)

      assert :ok =
               LocalClusterRegistry.register_name({:agent, "agent-2"}, self(), metadata, state)

      # Both should be findable
      assert {:ok, {pid1, _}} = LocalClusterRegistry.lookup_name({:agent, "agent-1"}, state)
      assert {:ok, {pid2, _}} = LocalClusterRegistry.lookup_name({:agent, "agent-2"}, state)
      assert pid1 == self()
      assert pid2 == self()
    end

    test "unregisters agent successfully", %{registry_state: state} do
      agent_id = "agent-456"
      metadata = %{type: :coordinator_agent}

      # MOCK: Use local registry for unit testing
      :ok = LocalClusterRegistry.register_name({:agent, agent_id}, self(), metadata, state)

      # Verify registration exists
      assert {:ok, {_pid, _metadata}} =
               LocalClusterRegistry.lookup_name({:agent, agent_id}, state)

      # Unregister
      assert :ok = LocalClusterRegistry.unregister_name({:agent, agent_id}, state)

      # Should no longer be found
      assert {:error, :not_registered} =
               LocalClusterRegistry.lookup_name({:agent, agent_id}, state)
    end

    test "handles lookup of non-existent agent", %{registry_state: state} do
      # MOCK: Use local registry for unit testing
      assert {:error, :not_registered} =
               LocalClusterRegistry.lookup_name({:agent, "non-existent"}, state)
    end

    test "updates agent metadata", %{registry_state: state} do
      agent_id = "agent-789"
      initial_metadata = %{type: :worker_agent, status: :initializing}
      updated_metadata = %{type: :worker_agent, status: :ready}

      # MOCK: Use local registry for unit testing
      :ok =
        LocalClusterRegistry.register_name({:agent, agent_id}, self(), initial_metadata, state)

      # Update metadata
      assert :ok =
               LocalClusterRegistry.update_metadata({:agent, agent_id}, updated_metadata, state)

      # Verify updated metadata
      assert {:ok, {_pid, ^updated_metadata}} =
               LocalClusterRegistry.lookup_name({:agent, agent_id}, state)
    end
  end

  describe "group registration" do
    test "registers multiple agents under same group", %{registry_state: state} do
      group = :code_analyzers
      metadata1 = %{specialization: :python}
      metadata2 = %{specialization: :elixir}

      # MOCK: Use local registry for unit testing
      assert :ok = LocalClusterRegistry.register_group(group, self(), metadata1, state)

      assert :ok =
               LocalClusterRegistry.register_group(group, spawn(fn -> :ok end), metadata2, state)

      # Should find both processes in group
      assert {:ok, group_members} = LocalClusterRegistry.lookup_group(group, state)
      assert length(group_members) == 2

      # Verify metadata is preserved
      self_pid = self()
      self_entry = Enum.find(group_members, fn {pid, _} -> pid == self_pid end)
      assert {^self_pid, ^metadata1} = self_entry
    end

    test "handles empty group lookup", %{registry_state: state} do
      # MOCK: Use local registry for unit testing
      assert {:error, :group_not_found} = LocalClusterRegistry.lookup_group(:empty_group, state)
    end

    test "unregisters from group", %{registry_state: state} do
      group = :test_workers
      metadata = %{task_type: :analysis}

      # MOCK: Use local registry for unit testing
      :ok = LocalClusterRegistry.register_group(group, self(), metadata, state)

      # Verify in group
      self_pid = self()
      assert {:ok, [{^self_pid, ^metadata}]} = LocalClusterRegistry.lookup_group(group, state)

      # Unregister from group
      assert :ok = LocalClusterRegistry.unregister_group(group, self(), state)

      # Group should now be empty/not found
      assert {:error, :group_not_found} = LocalClusterRegistry.lookup_group(group, state)
    end
  end

  describe "registry patterns" do
    test "pattern matching finds agents by type", %{registry_state: state} do
      # Register different types of agents
      # MOCK: Use local registry for unit testing
      :ok =
        LocalClusterRegistry.register_name({:agent, "llm-1"}, self(), %{type: :llm_agent}, state)

      :ok =
        LocalClusterRegistry.register_name(
          {:agent, "worker-1"},
          self(),
          %{type: :worker_agent},
          state
        )

      :ok =
        LocalClusterRegistry.register_name(
          {:service, "gateway"},
          self(),
          %{type: :gateway},
          state
        )

      # Pattern match for all agents (not services)
      assert {:ok, matches} = LocalClusterRegistry.match({:agent, :_}, state)

      # Should find both agents
      assert length(matches) == 2
      agent_names = Enum.map(matches, fn {name, _pid, _metadata} -> name end)
      assert {:agent, "llm-1"} in agent_names
      assert {:agent, "worker-1"} in agent_names
      refute {:service, "gateway"} in agent_names
    end

    test "counts total registrations", %{registry_state: state} do
      # MOCK: Use local registry for unit testing
      assert {:ok, 0} = LocalClusterRegistry.count(state)

      # Add some registrations
      :ok = LocalClusterRegistry.register_name({:agent, "test-1"}, self(), %{}, state)
      :ok = LocalClusterRegistry.register_name({:agent, "test-2"}, self(), %{}, state)

      assert {:ok, 2} = LocalClusterRegistry.count(state)
    end
  end

  describe "TTL support" do
    test "registers with time-to-live", %{registry_state: state} do
      agent_id = "temp-agent"
      # 100ms for quick test
      ttl = 100
      metadata = %{temporary: true}

      # MOCK: Use local registry for unit testing
      assert :ok =
               LocalClusterRegistry.register_with_ttl(
                 {:agent, agent_id},
                 self(),
                 ttl,
                 metadata,
                 state
               )

      # Should be immediately findable
      self_pid = self()

      assert {:ok, {^self_pid, ^metadata}} =
               LocalClusterRegistry.lookup_name({:agent, agent_id}, state)

      # After TTL expires, should be gone (this would be implemented in the real registry)
      # For now, just verify the registration was successful
    end
  end

  describe "health and monitoring" do
    test "reports registry health", %{registry_state: state} do
      # MOCK: Use local registry for unit testing
      assert {:ok, health} = LocalClusterRegistry.health_check(state)

      # Health should contain expected keys
      assert Map.has_key?(health, :node_count)
      assert Map.has_key?(health, :registration_count)
      assert Map.has_key?(health, :nodes)
      assert Map.has_key?(health, :sync_status)
    end

    test "sets up monitoring for agent", %{registry_state: state} do
      agent_id = "monitored-agent"
      metadata = %{monitored: true}

      # MOCK: Use local registry for unit testing
      :ok = LocalClusterRegistry.register_name({:agent, agent_id}, self(), metadata, state)

      # Set up monitoring
      assert {:ok, monitor_ref} = LocalClusterRegistry.monitor({:agent, agent_id}, state)
      assert is_reference(monitor_ref)
    end
  end
end
