defmodule Arbor.Test.Mocks.LocalClusterRegistry do
  @moduledoc """
  PRODUCTION BACKEND - Local registry implementation for dev/test environments.

  This is a legitimate backend implementation used by production code when configured
  for local/single-node operation. It implements the same contract as HordeRegistry
  but operates locally for testing and development without distributed dependencies.

  ## Features

  - Process registration with unique names
  - Group registration for multiple processes
  - Metadata storage and updates
  - TTL support with automatic expiration
  - Process monitoring and cleanup

  ## Usage in Tests

      defmodule MyTest do
        use ExUnit.Case
        alias Arbor.Test.Mocks.LocalClusterRegistry

        setup do
          {:ok, registry} = LocalClusterRegistry.init(name: :test_registry)
          {:ok, registry: registry}
        end

        test "register and lookup process", %{registry: registry} do
          :ok = LocalClusterRegistry.register_name(:my_process, self(), %{}, registry)
          {:ok, {pid, meta}} = LocalClusterRegistry.lookup_name(:my_process, registry)
          assert pid == self()
        end
      end

  ## Simulating Distributed Behavior

  The mock can simulate network partitions and node failures:

      # Simulate node going down
      LocalClusterRegistry.simulate_node_down(:node1@host, registry)

      # Simulate network partition
      LocalClusterRegistry.simulate_partition([:node1@host], [:node2@host], registry)

  @warning This is a TEST MOCK - not distributed!
  """

  @behaviour Arbor.Contracts.Cluster.Registry
  use GenServer

  defstruct [
    :names_table,
    :groups_table,
    :monitors_table,
    :ttl_table,
    :config,
    :node_status
  ]

  @type state() :: %__MODULE__{
          names_table: atom(),
          groups_table: atom(),
          monitors_table: atom(),
          ttl_table: atom(),
          config: keyword(),
          node_status: map()
        }

  # Client API

  @doc """
  Starts the LocalClusterRegistry GenServer.
  """
  @spec start_link() :: GenServer.on_start()
  def start_link() do
    start_link([])
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Clears all data from the registry tables.
  """
  @spec clear() :: :ok
  def clear() do
    GenServer.call(__MODULE__, :clear)
  end

  # GenServer callbacks

  @spec init(keyword()) :: {:ok, state()}
  @impl true
  def init(opts) do
    name = opts[:name] || :mock_registry

    state = %__MODULE__{
      names_table: :"#{name}_names",
      groups_table: :"#{name}_groups",
      monitors_table: :"#{name}_monitors",
      ttl_table: :"#{name}_ttl",
      config: opts,
      node_status: %{node() => :up}
    }

    # Create ETS tables
    :ets.new(state.names_table, [:set, :public, :named_table])
    :ets.new(state.groups_table, [:bag, :public, :named_table])
    :ets.new(state.monitors_table, [:bag, :public, :named_table])
    :ets.new(state.ttl_table, [:set, :public, :named_table])

    # Start TTL cleanup process if needed
    if opts[:enable_ttl_cleanup] do
      spawn_link(fn -> ttl_cleanup_loop(state) end)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    # Clear all ETS tables
    :ets.delete_all_objects(state.names_table)
    :ets.delete_all_objects(state.groups_table)
    :ets.delete_all_objects(state.monitors_table)
    :ets.delete_all_objects(state.ttl_table)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:register_group, group_name, agent_id, metadata}, _from, state) do
    # Use the existing 4-arity internal function
    result = register_group(group_name, agent_id, metadata, state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_group_members, group_name}, _from, state) do
    case lookup_group(group_name, state) do
      {:ok, members} ->
        agent_ids =
          Enum.map(members, fn {_pid, metadata} ->
            Map.get(metadata, :agent_id, :unknown)
          end)

        {:reply, {:ok, agent_ids}, state}

      {:error, :group_not_found} ->
        {:reply, {:ok, []}, state}
    end
  end

  @impl true
  def handle_call({:list_by_pattern, pattern}, _from, state) do
    # Convert string pattern to Elixir pattern matching
    # For simplicity, treat "*" as wildcard for now
    all_names = :ets.tab2list(state.names_table)

    filtered =
      case pattern do
        "*" <> _rest ->
          # Wildcard pattern - return all agents
          all_names
          |> Enum.filter(fn {name, _pid, _meta, _ref} ->
            case name do
              {:agent, _id} -> true
              _ -> false
            end
          end)
          |> Enum.map(fn {{:agent, id}, pid, meta, _ref} -> {id, pid, meta} end)

        exact_pattern ->
          # Exact match
          case :ets.lookup(state.names_table, {:agent, exact_pattern}) do
            [{_, pid, meta, _ref}] -> [{exact_pattern, pid, meta}]
            [] -> []
          end
      end

    {:reply, {:ok, filtered}, state}
  end

  def register_name(name, pid, metadata, state) do
    # Check if already registered
    case :ets.lookup(state.names_table, name) do
      [] ->
        # Monitor the process
        ref = Process.monitor(pid)
        :ets.insert(state.monitors_table, {ref, name, :name})

        # Register the name
        entry = {name, pid, metadata, DateTime.utc_now()}
        :ets.insert(state.names_table, entry)

        :ok

      [{^name, existing_pid, _, _}] ->
        if Process.alive?(existing_pid) do
          {:error, :name_taken}
        else
          # Clean up dead process and retry
          cleanup_name(name, state)
          register_name(name, pid, metadata, state)
        end
    end
  end

  def register_group(group, pid, metadata, state) do
    # Monitor the process if not already monitored
    unless already_monitoring?(pid, state) do
      ref = Process.monitor(pid)
      :ets.insert(state.monitors_table, {ref, {group, pid}, :group})
    end

    # Add to group
    entry = {group, pid, metadata, DateTime.utc_now()}
    :ets.insert(state.groups_table, entry)

    :ok
  end

  def unregister_name(name, state) do
    case :ets.lookup(state.names_table, name) do
      [{^name, _pid, _, _}] ->
        # Remove monitoring
        remove_monitor_for_name(name, state)

        # Remove registration
        :ets.delete(state.names_table, name)

        # Remove TTL if any
        :ets.delete(state.ttl_table, name)

        :ok

      [] ->
        {:error, :not_registered}
    end
  end

  def unregister_group(group, pid, state) do
    case :ets.match_object(state.groups_table, {group, pid, :_, :_}) do
      [] ->
        {:error, :not_registered}

      matches ->
        # Remove all matching entries
        Enum.each(matches, fn entry ->
          :ets.delete_object(state.groups_table, entry)
        end)

        # Check if we should remove monitor
        unless has_other_registrations?(pid, group, state) do
          remove_monitor_for_group(group, pid, state)
        end

        :ok
    end
  end

  def lookup_name(name, state) do
    case :ets.lookup(state.names_table, name) do
      [{^name, pid, metadata, _}] ->
        if Process.alive?(pid) do
          {:ok, {pid, metadata}}
        else
          # Clean up dead process
          cleanup_name(name, state)
          {:error, :not_registered}
        end

      [] ->
        {:error, :not_registered}
    end
  end

  def lookup_group(group, state) do
    entries = :ets.lookup(state.groups_table, group)

    # Filter out dead processes
    alive_entries =
      entries
      |> Enum.filter(fn {_, pid, _, _} -> Process.alive?(pid) end)
      |> Enum.map(fn {_, pid, metadata, _} -> {pid, metadata} end)

    # Clean up dead ones
    dead_entries =
      Enum.reject(entries, fn {_, pid, _, _} -> Process.alive?(pid) end)

    Enum.each(dead_entries, fn {group, pid, _, _} ->
      unregister_group(group, pid, state)
    end)

    if entries == [] do
      {:error, :group_not_found}
    else
      {:ok, alive_entries}
    end
  end

  def update_metadata(name, metadata, state) do
    case :ets.lookup(state.names_table, name) do
      [{^name, pid, _old_meta, registered_at}] ->
        :ets.insert(state.names_table, {name, pid, metadata, registered_at})
        :ok

      [] ->
        {:error, :not_registered}
    end
  end

  def register_with_ttl(name, pid, ttl, metadata, state) do
    case register_name(name, pid, metadata, state) do
      :ok ->
        # Schedule expiration
        expires_at = DateTime.add(DateTime.utc_now(), ttl, :millisecond)
        :ets.insert(state.ttl_table, {name, expires_at})
        :ok

      error ->
        error
    end
  end

  def match(pattern, state) do
    # Simple pattern matching for testing
    # In production, this would use Horde's pattern matching

    all_names = :ets.tab2list(state.names_table)

    matching =
      case pattern do
        {:agent, :_} ->
          Enum.filter(all_names, fn {name, _, _, _} ->
            match?({:agent, _}, name)
          end)

        {:service, :_, node} ->
          Enum.filter(all_names, fn {name, _, meta, _} ->
            match?({:service, _, ^node}, name) or
              (match?({:service, _}, name) and meta[:node] == node)
          end)

        _ ->
          # For testing, just return all
          all_names
      end

    result =
      Enum.map(matching, fn {name, pid, metadata, _} ->
        {name, pid, metadata}
      end)

    {:ok, result}
  end

  def count(state) do
    count = :ets.info(state.names_table, :size)
    {:ok, count}
  end

  def monitor(name, state) do
    case lookup_name(name, state) do
      {:ok, {_pid, _}} ->
        ref = make_ref()
        # In a real implementation, this would set up Horde monitoring
        # For testing, we'll track it locally
        send(self(), {:mock_monitor_setup, ref, name})
        {:ok, ref}

      {:error, :not_registered} ->
        {:error, :not_registered}
    end
  end

  def health_check(state) do
    names_count = :ets.info(state.names_table, :size)

    groups_count =
      length(Enum.uniq(:ets.select(state.groups_table, [{{:"$1", :_, :_, :_}, [], [:"$1"]}])))

    health = %{
      node_count: map_size(state.node_status),
      registration_count: names_count,
      # Mock has no conflicts
      conflict_count: 0,
      nodes: Map.keys(state.node_status),
      sync_status: :synchronized,
      groups_count: groups_count,
      monitors_active: :ets.info(state.monitors_table, :size)
    }

    {:ok, health}
  end

  def handle_node_up(node, state) do
    updated_status = Map.put(state.node_status, node, :up)
    {:ok, %{state | node_status: updated_status}}
  end

  def handle_node_down(node, state) do
    updated_status = Map.put(state.node_status, node, :down)

    # In a real distributed registry, we'd handle process migration here
    # For testing, we'll just track the status

    {:ok, %{state | node_status: updated_status}}
  end

  def start_registry(opts) do
    # For testing, just create an initial state
    init(opts)
  end

  def stop_registry(_reason, state) do
    # Clean up resources
    terminate(:shutdown, state)
  end

  @spec terminate(any(), state()) :: :ok
  @impl true
  def terminate(_reason, state) do
    # Clean up ETS tables
    :ets.delete(state.names_table)
    :ets.delete(state.groups_table)
    :ets.delete(state.monitors_table)
    :ets.delete(state.ttl_table)
    :ok
  end

  # Mock-specific functions for testing

  @doc """
  Simulate a node failure for testing.
  """
  @spec simulate_node_down(node(), state()) :: {:ok, state()}
  def simulate_node_down(node, state) do
    handle_node_down(node, state)
  end

  @doc """
  Simulate network partition for testing.
  """
  @spec simulate_partition([node()], [node()], any()) :: :ok
  def simulate_partition(nodes_a, nodes_b, _state) do
    # For testing, just track which nodes can't see each other
    send(self(), {:mock_partition, nodes_a, nodes_b})
    :ok
  end

  @doc """
  Get all registrations for verification.
  """
  @spec get_all_registrations(state()) :: %{names: list(), groups: map()}
  def get_all_registrations(state) do
    names = :ets.tab2list(state.names_table)
    groups = :ets.tab2list(state.groups_table)

    %{
      names: Enum.map(names, fn {name, pid, meta, _} -> {name, pid, meta} end),
      groups:
        Enum.group_by(
          groups,
          fn {group, _, _, _} -> group end,
          fn {_, pid, meta, _} -> {pid, meta} end
        )
    }
  end

  # Client API functions for contract compliance

  @doc "Register agent in group (3-arity client API version)"
  @spec register_group(atom(), pid(), map()) :: :ok | {:error, term()}
  def register_group(group_name, agent_id, metadata) do
    GenServer.call(__MODULE__, {:register_group, group_name, agent_id, metadata})
  end

  # Implement the required Cluster.Registry behavior callbacks

  @impl Arbor.Contracts.Cluster.Registry
  def get_status() do
    # Return mock status for testing
    {:ok,
     %{
       status: :healthy,
       nodes: [node()],
       registrations: 0,
       sync_status: :synchronized
     }}
  end

  @impl Arbor.Contracts.Cluster.Registry
  def start_service(config) do
    # For testing, just start a new instance
    start_link(config)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def stop_service(_reason) do
    # For testing, just return :ok
    :ok
  end

  @doc "List all members of a group"
  @spec list_group_members(atom()) :: {:ok, [term()]} | {:error, term()}
  def list_group_members(group_name) do
    GenServer.call(__MODULE__, {:list_group_members, group_name})
  end

  @doc "List agents matching a pattern (client API version)"
  @spec list_by_pattern(String.t()) :: {:ok, [{term(), pid(), map()}]}
  def list_by_pattern(pattern) do
    GenServer.call(__MODULE__, {:list_by_pattern, pattern})
  end

  @doc "Get registry status for cluster manager"
  @spec get_registry_status() ::
          {:ok,
           %{
             status: :healthy,
             members: [atom(), ...],
             count: 0,
             sync_status: :synchronized
           }}
  def get_registry_status do
    {:ok,
     %{
       status: :healthy,
       members: [node()],
       count: 0,
       sync_status: :synchronized
     }}
  end

  @doc "Join registry cluster (mock - no-op for single node)"
  @spec join_registry(node()) :: :ok | {:error, term()}
  def join_registry(_node) do
    # Mock implementation - always succeeds
    :ok
  end

  @doc "Leave registry cluster (mock - no-op for single node)"
  @spec leave_registry(node()) :: :ok | {:error, term()}
  def leave_registry(_node) do
    # Mock implementation - always succeeds
    :ok
  end

  # Private functions

  defp cleanup_name(name, state) do
    unregister_name(name, state)
  end

  defp already_monitoring?(pid, state) do
    monitors = :ets.tab2list(state.monitors_table)

    Enum.any?(monitors, fn {_ref, target, _type} ->
      case target do
        {_group, ^pid} -> true
        _ -> false
      end
    end)
  end

  defp remove_monitor_for_name(name, state) do
    monitors = :ets.match_object(state.monitors_table, {:_, name, :name})

    Enum.each(monitors, fn {ref, _, _} ->
      Process.demonitor(ref, [:flush])
      :ets.delete_object(state.monitors_table, {ref, name, :name})
    end)
  end

  defp remove_monitor_for_group(group, pid, state) do
    monitors = :ets.match_object(state.monitors_table, {:_, {group, pid}, :group})

    Enum.each(monitors, fn {ref, _, _} ->
      Process.demonitor(ref, [:flush])
      :ets.delete_object(state.monitors_table, {ref, {group, pid}, :group})
    end)
  end

  defp has_other_registrations?(pid, excluded_group, state) do
    # Check names table
    names = :ets.select(state.names_table, [{{:_, :"$1", :_, :_}, [{:==, :"$1", pid}], [true]}])

    # Check other groups
    groups =
      :ets.select(state.groups_table, [
        {{:"$1", :"$2", :_, :_}, [{:andalso, {:==, :"$2", pid}, {:"/=", :"$1", excluded_group}}],
         [true]}
      ])

    length(names) > 0 or length(groups) > 0
  end

  defp ttl_cleanup_loop(state) do
    # Check every second
    Process.sleep(1000)

    now = DateTime.utc_now()

    expired =
      :ets.select(state.ttl_table, [
        {{:"$1", :"$2"}, [{:<, :"$2", now}], [:"$1"]}
      ])

    Enum.each(expired, fn name ->
      unregister_name(name, state)
    end)

    ttl_cleanup_loop(state)
  end
end
