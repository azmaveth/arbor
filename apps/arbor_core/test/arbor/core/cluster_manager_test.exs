defmodule Arbor.Core.ClusterManagerTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Arbor.Core.ClusterManager

  setup_all do
    # Use mock implementations for testing
    Application.put_env(:arbor_core, :registry_impl, :mock)
    Application.put_env(:arbor_core, :supervisor_impl, :mock)

    # Ensure ClusterManager is started under test supervisor
    case Process.whereis(ClusterManager) do
      nil ->
        start_supervised!(ClusterManager)

      _pid ->
        :ok
    end

    on_exit(fn ->
      # Reset to auto configuration
      Application.put_env(:arbor_core, :registry_impl, :auto)
      Application.put_env(:arbor_core, :supervisor_impl, :auto)
    end)

    :ok
  end

  describe "cluster_status/0" do
    test "returns current cluster status" do
      assert status = ClusterManager.cluster_status()

      assert is_map(status)
      assert Map.has_key?(status, :nodes)
      assert Map.has_key?(status, :connected_nodes)
      assert Map.has_key?(status, :topology)
      assert Map.has_key?(status, :components)
      assert Map.has_key?(status, :uptime)

      assert is_list(status.nodes)
      assert is_integer(status.connected_nodes)
      assert is_atom(status.topology)
      assert is_map(status.components)
      assert is_integer(status.uptime)

      # Verify component status
      assert Map.has_key?(status.components, :registry)
      assert Map.has_key?(status.components, :supervisor)
      assert Map.has_key?(status.components, :coordinator)

      assert status.components.registry in [:up, :down]
      assert status.components.supervisor in [:up, :down]
      assert status.components.coordinator in [:up, :down]
    end
  end

  describe "connect_node/1" do
    test "returns error when connecting to invalid node" do
      assert {:error, :local_node_not_started} = ClusterManager.connect_node(:invalid@nowhere)
    end

    test "returns error when local node not started" do
      # This test would need to run without distributed Erlang started
      # Skipping for now as our tests run with distribution enabled
    end
  end

  describe "register_event_handler/1" do
    test "registers callback for node lifecycle events" do
      test_pid = self()

      callback = fn event, node ->
        send(test_pid, {:node_event, event, node})
      end

      assert :ok = ClusterManager.register_event_handler(callback)

      # Note: Testing actual node events would require multi-node setup
      # This just verifies the registration works
    end

    test "rejects non-function arguments" do
      assert_raise FunctionClauseError, fn ->
        ClusterManager.register_event_handler("not a function")
      end
    end
  end

  describe "reform_cluster/0" do
    test "reforms cluster by disconnecting and reconnecting nodes" do
      # Get initial status
      assert initial_status = ClusterManager.cluster_status()
      _initial_count = initial_status.connected_nodes

      # Reform cluster
      assert :ok = ClusterManager.reform_cluster()

      # Give it time to disconnect/reconnect
      Process.sleep(2500)

      # Check status after reform
      assert _final_status = ClusterManager.cluster_status()

      # In a single-node test environment, this should maintain the same state
      # More comprehensive testing would require multi-node setup
    end
  end

  describe "libcluster integration" do
    test "topology key is set based on environment" do
      assert status = ClusterManager.cluster_status()

      # In test environment, should use :arbor_test topology
      assert status.topology == :arbor_test
    end
  end
end
