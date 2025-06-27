defmodule Arbor.Test.Support.InfrastructureManager do
  @moduledoc """
  Singleton infrastructure manager for integration tests.

  This module ensures that test infrastructure (Horde, PubSub, etc.) is started
  exactly once for the entire test suite, regardless of how many test modules
  use IntegrationCase.

  It uses a combination of techniques:
  - GenServer singleton pattern for coordination
  - Atomic reference counting for cleanup
  - Process monitoring for crash recovery
  - Idempotent operations for all infrastructure components
  """

  use GenServer
  require Logger

  @name __MODULE__
  @infrastructure_key :arbor_test_infrastructure
  @setup_timeout 10_000

  # Client API

  @doc """
  Ensures infrastructure is started and returns when ready.
  Safe to call multiple times - will only start infrastructure once.
  """
  def ensure_started do
    # Start the manager if not already running
    case GenServer.start(@name, :ok, name: @name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "Failed to start infrastructure manager: #{inspect(reason)}"
    end

    # Request infrastructure setup
    GenServer.call(@name, :ensure_infrastructure, @setup_timeout)
  end

  @doc """
  Registers a test module as using the infrastructure.
  Returns a cleanup function that should be called in on_exit.
  """
  def register_user(test_module) do
    GenServer.call(@name, {:register_user, test_module})

    # Return cleanup function
    fn ->
      try do
        GenServer.call(@name, {:unregister_user, test_module}, 5_000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  @doc """
  Checks if infrastructure is currently running.
  """
  def infrastructure_running? do
    case Process.whereis(@name) do
      nil -> false
      pid -> GenServer.call(pid, :is_running)
    end
  end

  # Server callbacks

  @impl true
  def init(:ok) do
    # Set trap_exit to handle crashes in infrastructure
    Process.flag(:trap_exit, true)

    state = %{
      setup_status: :not_started,
      setup_pid: nil,
      users: MapSet.new(),
      infrastructure_pids: %{},
      setup_callbacks: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_infrastructure, from, %{setup_status: :not_started} = state) do
    # Start setup asynchronously
    parent = self()

    setup_pid =
      spawn_link(fn ->
        try do
          setup_infrastructure(parent)
        catch
          kind, reason ->
            Logger.error(
              "InfrastructureManager: Setup process crashed: #{kind} #{inspect(reason)}"
            )

            send(parent, {:setup_failed, {kind, reason}})
        end
      end)

    # Add a timeout to detect hanging setup
    Process.send_after(self(), {:setup_timeout, setup_pid}, 8000)

    new_state = %{
      state
      | setup_status: :setting_up,
        setup_pid: setup_pid,
        setup_callbacks: [from]
    }

    {:noreply, new_state}
  end

  def handle_call(:ensure_infrastructure, from, %{setup_status: :setting_up} = state) do
    # Add callback to be notified when setup completes
    new_state = %{state | setup_callbacks: [from | state.setup_callbacks]}
    {:noreply, new_state}
  end

  def handle_call(:ensure_infrastructure, _from, %{setup_status: :ready} = state) do
    # Infrastructure already set up
    {:reply, :ok, state}
  end

  def handle_call(:ensure_infrastructure, _from, %{setup_status: :failed} = state) do
    # Previous setup failed
    {:reply, {:error, :setup_failed}, state}
  end

  def handle_call({:register_user, module}, _from, state) do
    new_state = %{state | users: MapSet.put(state.users, module)}
    {:reply, :ok, new_state}
  end

  def handle_call({:unregister_user, module}, _from, state) do
    new_users = MapSet.delete(state.users, module)
    new_state = %{state | users: new_users}

    # If no more users, schedule cleanup
    if MapSet.size(new_users) == 0 do
      send(self(), :maybe_cleanup)
    end

    {:reply, :ok, new_state}
  end

  def handle_call(:is_running, _from, state) do
    {:reply, state.setup_status == :ready, state}
  end

  @impl true
  def handle_info({:setup_complete, pids}, state) do
    # Notify all waiting callers
    for from <- state.setup_callbacks do
      GenServer.reply(from, :ok)
    end

    new_state = %{
      state
      | setup_status: :ready,
        setup_pid: nil,
        infrastructure_pids: pids,
        setup_callbacks: []
    }

    {:noreply, new_state}
  end

  def handle_info({:setup_failed, reason}, state) do
    Logger.error("Infrastructure setup failed: #{inspect(reason)}")

    # Notify all waiting callers
    for from <- state.setup_callbacks do
      GenServer.reply(from, {:error, :setup_failed})
    end

    new_state = %{state | setup_status: :failed, setup_pid: nil, setup_callbacks: []}

    {:noreply, new_state}
  end

  def handle_info(:maybe_cleanup, %{users: users} = state) when map_size(users) == 0 do
    # No more users, clean up after a delay to handle rapid test restarts
    Process.send_after(self(), :cleanup, 1_000)
    {:noreply, state}
  end

  def handle_info(:maybe_cleanup, state) do
    # Users were added, cancel cleanup
    {:noreply, state}
  end

  def handle_info(:cleanup, %{users: users} = state) when map_size(users) == 0 do
    # Still no users, perform cleanup
    cleanup_infrastructure(state.infrastructure_pids)
    {:stop, :normal, state}
  end

  def handle_info(:cleanup, state) do
    # Users were added, don't cleanup
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{setup_pid: pid} = state) do
    # Setup process crashed
    if reason == :normal do
      # Normal exit, might have completed successfully
      # Wait for the actual setup result message
      {:noreply, state}
    else
      handle_info({:setup_failed, reason}, state)
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Some infrastructure process crashed, but we'll handle it gracefully
    {:noreply, state}
  end

  def handle_info({:setup_timeout, setup_pid}, %{setup_pid: setup_pid} = state) do
    # Setup is taking too long
    Logger.error("InfrastructureManager: Setup timeout - killing setup process")
    Process.exit(setup_pid, :kill)

    # Notify waiting callers
    for from <- state.setup_callbacks do
      GenServer.reply(from, {:error, :setup_timeout})
    end

    new_state = %{state | setup_status: :failed, setup_pid: nil, setup_callbacks: []}

    {:noreply, new_state}
  end

  def handle_info({:setup_timeout, _}, state) do
    # Timeout for a different setup process, ignore
    {:noreply, state}
  end

  # Private functions

  defp setup_infrastructure(parent) do
    try do
      pids = %{}

      Logger.info("InfrastructureManager: Starting distributed Erlang")
      # Start distributed Erlang
      pids = Map.put(pids, :distributed_erlang, start_distributed_erlang())

      Logger.info("InfrastructureManager: Starting PubSub")
      # Start PubSub
      pids = Map.put(pids, :pubsub, start_or_get_pubsub())

      Logger.info("InfrastructureManager: Starting Task Supervisor")
      # Start Task Supervisor
      pids = Map.put(pids, :task_supervisor, start_or_get_task_supervisor())

      Logger.info("InfrastructureManager: Starting Horde Supervisor")
      # Start Horde Supervisor
      pids = Map.put(pids, :horde_supervisor, start_horde_supervisor())

      Logger.info("InfrastructureManager: Starting Horde Coordinator")
      # Start Horde Coordinator
      pids = Map.put(pids, :horde_coordinator, start_horde_coordinator())

      Logger.info("InfrastructureManager: Starting Agent Reconciler")
      # Start Agent Reconciler
      pids = Map.put(pids, :agent_reconciler, start_or_get_agent_reconciler())

      Logger.info("InfrastructureManager: Starting Cluster Manager")
      # Start Cluster Manager
      pids = Map.put(pids, :cluster_manager, start_or_get_cluster_manager())

      Logger.info("InfrastructureManager: Starting Sessions Manager")
      # Start Sessions Manager
      pids = Map.put(pids, :sessions_manager, start_or_get_sessions_manager())

      Logger.info("InfrastructureManager: Starting Gateway")
      # Start Gateway
      pids = Map.put(pids, :gateway, start_or_get_gateway())

      Logger.info("InfrastructureManager: Setting up cluster membership")
      # Setup cluster membership
      setup_cluster_membership()

      Logger.info("InfrastructureManager: Waiting for infrastructure to be ready")
      # Wait for everything to be ready
      wait_for_infrastructure_ready()

      Logger.info("InfrastructureManager: Setup complete")
      send(parent, {:setup_complete, pids})
    rescue
      error ->
        Logger.error("InfrastructureManager: Setup failed with error: #{inspect(error)}")
        Logger.error("InfrastructureManager: Stacktrace: #{inspect(__STACKTRACE__)}")
        send(parent, {:setup_failed, error})
    catch
      :exit, reason ->
        Logger.error("InfrastructureManager: Setup failed with exit: #{inspect(reason)}")
        send(parent, {:setup_failed, {:exit, reason}})
    end
  end

  defp start_distributed_erlang do
    # Check if distributed Erlang is already running
    case node() do
      :nonode@nohost ->
        # Not running, try to start it
        # Use a unique node name to avoid conflicts
        timestamp = System.unique_integer([:positive])
        node_name = "arbor_test_#{timestamp}@localhost"

        case :net_kernel.start([String.to_atom(node_name), :shortnames]) do
          {:ok, _} ->
            # Set the cookie AFTER starting distributed mode
            :erlang.set_cookie(node(), :arbor_test_cookie)
            Logger.info("InfrastructureManager: Started distributed Erlang as #{node()}")
            :ok

          {:error, {:already_started, _}} ->
            Logger.info("InfrastructureManager: Distributed Erlang already started as #{node()}")
            :ok

          {:error, reason} ->
            # In ExUnit tests, distributed Erlang may be disabled
            # This is okay for single-node integration tests
            Logger.warning(
              "InfrastructureManager: Could not start distributed Erlang: #{inspect(reason)}"
            )

            Logger.warning("InfrastructureManager: Continuing without distributed features")
            :ok
        end

      node_name ->
        # Already running with a node name
        Logger.info("InfrastructureManager: Distributed Erlang already running as #{node_name}")
        :ok
    end
  end

  defp start_or_get_pubsub do
    case GenServer.whereis(Arbor.Core.PubSub) do
      nil ->
        {:ok, pid} = Phoenix.PubSub.Supervisor.start_link(name: Arbor.Core.PubSub)
        pid

      pid ->
        pid
    end
  end

  defp start_or_get_task_supervisor do
    case Process.whereis(Arbor.TaskSupervisor) do
      nil ->
        {:ok, pid} = Task.Supervisor.start_link(name: Arbor.TaskSupervisor)
        pid

      pid ->
        pid
    end
  end

  defp start_horde_supervisor do
    # For integration tests, we need to ensure Horde implementations are used
    Application.put_env(:arbor_core, :registry_impl, :horde)
    Application.put_env(:arbor_core, :supervisor_impl, :horde)
    Application.put_env(:arbor_core, :coordinator_impl, :horde)

    # Check if the supervisor is already running from previous tests
    supervisor_pid = Process.whereis(Arbor.Core.HordeSupervisorSupervisor)
    agent_registry_pid = Process.whereis(Arbor.Core.HordeAgentRegistry)
    agent_supervisor_pid = Process.whereis(Arbor.Core.HordeAgentSupervisor)
    checkpoint_registry_pid = Process.whereis(Arbor.Core.HordeCheckpointRegistry)

    cond do
      # All already running - reuse them
      supervisor_pid != nil and agent_registry_pid != nil and
        agent_supervisor_pid != nil and checkpoint_registry_pid != nil ->
        Logger.info("InfrastructureManager: Horde components already running, reusing")
        supervisor_pid

      # Partial state - clean up and restart
      supervisor_pid != nil or agent_registry_pid != nil or
        agent_supervisor_pid != nil or checkpoint_registry_pid != nil ->
        Logger.info("InfrastructureManager: Horde components in partial state, cleaning up")
        if supervisor_pid, do: Process.exit(supervisor_pid, :shutdown)
        if agent_registry_pid, do: Process.exit(agent_registry_pid, :shutdown)
        if agent_supervisor_pid, do: Process.exit(agent_supervisor_pid, :shutdown)
        if checkpoint_registry_pid, do: Process.exit(checkpoint_registry_pid, :shutdown)
        # Give more time for cleanup
        Process.sleep(200)
        start_fresh_horde_supervisor()

      # Nothing running - start fresh
      true ->
        Logger.info("InfrastructureManager: Starting fresh Horde components")
        start_fresh_horde_supervisor()
    end
  end

  defp start_fresh_horde_supervisor do
    # Ensure we're not trying to start clustered components
    Application.put_env(:libcluster, :topologies, [])

    case Arbor.Core.HordeSupervisor.start_supervisor() do
      {:ok, pid} ->
        Logger.info("InfrastructureManager: Horde supervisor started successfully")
        pid

      {:error, {:already_started, pid}} ->
        Logger.info("InfrastructureManager: Horde supervisor already started")
        pid

      {:error, reason} ->
        Logger.error(
          "InfrastructureManager: Failed to start Horde supervisor: #{inspect(reason)}"
        )

        raise "Failed to start Horde supervisor: #{inspect(reason)}"
    end
  end

  defp start_horde_coordinator do
    # Check if the coordinator is already running from previous tests
    coordinator_pid = Process.whereis(Arbor.Core.HordeCoordinatorSupervisor)
    registry_pid = Process.whereis(Arbor.Core.HordeCoordinationRegistry)

    cond do
      # Both already running - reuse them
      coordinator_pid != nil and registry_pid != nil ->
        coordinator_pid

      # Partial state - clean up and restart
      coordinator_pid != nil or registry_pid != nil ->
        if coordinator_pid, do: Process.exit(coordinator_pid, :shutdown)
        if registry_pid, do: Process.exit(registry_pid, :shutdown)
        Process.sleep(100)
        start_fresh_horde_coordinator()

      # Nothing running - start fresh
      true ->
        start_fresh_horde_coordinator()
    end
  end

  defp start_fresh_horde_coordinator do
    case Arbor.Core.HordeCoordinator.start_coordination() do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, reason} -> raise "Failed to start Horde coordinator: #{inspect(reason)}"
    end
  end

  defp start_or_get_agent_reconciler do
    case GenServer.whereis(Arbor.Core.AgentReconciler) do
      nil ->
        {:ok, pid} = Arbor.Core.AgentReconciler.start_link([])
        pid

      pid ->
        pid
    end
  end

  defp start_or_get_cluster_manager do
    case GenServer.whereis(Arbor.Core.ClusterManager) do
      nil ->
        # Start ClusterManager with test-specific config that disables libcluster
        config = [
          # Empty topologies for single-node testing
          topologies: [],
          # Skip libcluster startup in tests
          skip_libcluster: true
        ]

        case Arbor.Core.ClusterManager.start_link(config) do
          {:ok, pid} ->
            pid

          {:error, reason} ->
            Logger.error("Failed to start ClusterManager: #{inspect(reason)}")
            raise "Failed to start ClusterManager: #{inspect(reason)}"
        end

      pid ->
        pid
    end
  end

  defp start_or_get_sessions_manager do
    case GenServer.whereis(Arbor.Core.Sessions.Manager) do
      nil ->
        {:ok, pid} = Arbor.Core.Sessions.Manager.start_link([])
        pid

      pid ->
        pid
    end
  end

  defp start_or_get_gateway do
    case GenServer.whereis(Arbor.Core.Gateway) do
      nil ->
        {:ok, pid} = Arbor.Core.Gateway.start_link([])
        pid

      pid ->
        pid
    end
  end

  defp setup_cluster_membership do
    current_node = node()

    # Set cluster members for registries and supervisor
    Horde.Cluster.set_members(
      Arbor.Core.HordeAgentRegistry,
      [{Arbor.Core.HordeAgentRegistry, current_node}]
    )

    Horde.Cluster.set_members(
      Arbor.Core.HordeCheckpointRegistry,
      [{Arbor.Core.HordeCheckpointRegistry, current_node}]
    )

    Horde.Cluster.set_members(
      Arbor.Core.HordeAgentSupervisor,
      [{Arbor.Core.HordeAgentSupervisor, current_node}]
    )
  end

  defp wait_for_infrastructure_ready do
    Logger.info("InfrastructureManager: Waiting for infrastructure components...")

    # Wait for processes to be registered
    try do
      Arbor.Test.Support.AsyncHelpers.wait_until(
        fn ->
          pubsub_ready = GenServer.whereis(Arbor.Core.PubSub) != nil
          registry_ready = GenServer.whereis(Arbor.Core.HordeAgentRegistry) != nil
          supervisor_ready = GenServer.whereis(Arbor.Core.HordeAgentSupervisor) != nil
          reconciler_ready = GenServer.whereis(Arbor.Core.AgentReconciler) != nil

          Logger.debug(
            "InfrastructureManager: Component status - " <>
              "PubSub: #{pubsub_ready}, Registry: #{registry_ready}, " <>
              "Supervisor: #{supervisor_ready}, Reconciler: #{reconciler_ready}"
          )

          pubsub_ready and registry_ready and supervisor_ready and reconciler_ready
        end,
        timeout: 5000,
        initial_delay: 50
      )

      Logger.info("InfrastructureManager: Core components ready")

      # Try to wait for cluster membership, but don't fail if it times out
      try do
        wait_for_cluster_membership()
        Logger.info("InfrastructureManager: Cluster membership established")
      rescue
        _ ->
          Logger.warning(
            "InfrastructureManager: Cluster membership setup timed out, continuing anyway"
          )
      end

      # Try to wait for ETS tables, but don't fail if it times out
      try do
        wait_for_ets_tables()
        Logger.info("InfrastructureManager: ETS tables ready")
      rescue
        _ ->
          Logger.warning("InfrastructureManager: ETS table setup timed out, continuing anyway")
      end

      Logger.info("InfrastructureManager: Infrastructure is ready")
    rescue
      error ->
        Logger.error(
          "InfrastructureManager: Failed waiting for infrastructure: #{inspect(error)}"
        )

        reraise error, __STACKTRACE__
    end
  end

  defp wait_for_cluster_membership do
    current_node = node()

    Arbor.Test.Support.AsyncHelpers.wait_until(
      fn ->
        registry_members = Horde.Cluster.members(Arbor.Core.HordeAgentRegistry)
        supervisor_members = Horde.Cluster.members(Arbor.Core.HordeAgentSupervisor)

        registry_ready =
          Enum.any?(registry_members, fn
            {Arbor.Core.HordeAgentRegistry, node} when node == current_node -> true
            _ -> false
          end)

        supervisor_ready =
          Enum.any?(supervisor_members, fn
            {Arbor.Core.HordeAgentSupervisor, node} when node == current_node -> true
            _ -> false
          end)

        registry_ready and supervisor_ready
      end,
      timeout: 5000,
      initial_delay: 50
    )
  end

  defp wait_for_ets_tables do
    keys_table = :"keys_Elixir.Arbor.Core.HordeAgentRegistry"

    Arbor.Test.Support.AsyncHelpers.wait_until(
      fn ->
        :ets.info(keys_table) != :undefined
      end,
      timeout: 2000,
      initial_delay: 50
    )
  end

  defp cleanup_infrastructure(pids) do
    # Stop Horde components gracefully
    stop_horde_components()

    # Stop other managed processes
    for {_key, pid} <- pids, is_pid(pid) do
      try do
        Process.exit(pid, :shutdown)
      catch
        :exit, _ -> :ok
      end
    end

    # Stop distributed Erlang
    try do
      :net_kernel.stop()
    catch
      :exit, _ -> :ok
    end
  end

  defp stop_horde_components do
    components = [
      Arbor.Core.HordeCoordinationRegistry,
      Arbor.Core.HordeCoordinatorSupervisor,
      Arbor.Core.HordeAgentRegistry,
      Arbor.Core.HordeAgentSupervisor,
      Arbor.Core.HordeSupervisorSupervisor
    ]

    for component <- components do
      if pid = Process.whereis(component) do
        try do
          Process.exit(pid, :shutdown)
          Process.sleep(50)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end
end
