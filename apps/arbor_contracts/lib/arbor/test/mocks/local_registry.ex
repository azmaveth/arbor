defmodule Arbor.Test.Mocks.LocalRegistry do
  @moduledoc """
  TEST MOCK - DO NOT USE IN PRODUCTION

  Local, non-distributed registry for testing registry operations.
  This mock simulates distributed registry behavior in a single node.

  ## Features

  - Process registration with unique names
  - Group registration for multiple processes
  - Metadata storage and updates
  - TTL support with automatic expiration
  - Process monitoring and cleanup

  ## Usage in Tests

      defmodule MyTest do
        use ExUnit.Case
        alias Arbor.Test.Mocks.LocalRegistry
        
        setup do
          {:ok, registry} = LocalRegistry.init(name: :test_registry)
          {:ok, registry: registry}
        end
        
        test "register and lookup process", %{registry: registry} do
          :ok = LocalRegistry.register_name(:my_process, self(), %{}, registry)
          {:ok, {pid, meta}} = LocalRegistry.lookup_name(:my_process, registry)
          assert pid == self()
        end
      end

  ## Simulating Distributed Behavior

  The mock can simulate network partitions and node failures:

      # Simulate node going down
      LocalRegistry.simulate_node_down(:node1@host, registry)
      
      # Simulate network partition
      LocalRegistry.simulate_partition([:node1@host], [:node2@host], registry)

  @warning This is a TEST MOCK - not distributed!
  """

  @behaviour Arbor.Contracts.Cluster.Registry

  defstruct [
    :names_table,
    :groups_table,
    :monitors_table,
    :ttl_table,
    :config,
    :node_status
  ]

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

  @impl true
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

  @impl true
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

  @impl true
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

  @impl true
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

  @impl true
  def lookup_group(group, state) do
    entries = :ets.lookup(state.groups_table, group)

    # Filter out dead processes
    alive_entries =
      entries
      |> Enum.filter(fn {_, pid, _, _} -> Process.alive?(pid) end)
      |> Enum.map(fn {_, pid, metadata, _} -> {pid, metadata} end)

    # Clean up dead ones
    dead_entries =
      entries
      |> Enum.reject(fn {_, pid, _, _} -> Process.alive?(pid) end)

    Enum.each(dead_entries, fn {group, pid, _, _} ->
      unregister_group(group, pid, state)
    end)

    if entries == [] do
      {:error, :group_not_found}
    else
      {:ok, alive_entries}
    end
  end

  @impl true
  def update_metadata(name, metadata, state) do
    case :ets.lookup(state.names_table, name) do
      [{^name, pid, _old_meta, registered_at}] ->
        :ets.insert(state.names_table, {name, pid, metadata, registered_at})
        :ok

      [] ->
        {:error, :not_registered}
    end
  end

  @impl true
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

  @impl true
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

  @impl true
  def count(state) do
    count = :ets.info(state.names_table, :size)
    {:ok, count}
  end

  @impl true
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

  @impl true
  def health_check(state) do
    names_count = :ets.info(state.names_table, :size)

    groups_count =
      length(:ets.select(state.groups_table, [{{:"$1", :_, :_, :_}, [], [:"$1"]}]) |> Enum.uniq())

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

  @impl true
  def handle_node_up(node, state) do
    updated_status = Map.put(state.node_status, node, :up)
    {:ok, %{state | node_status: updated_status}}
  end

  @impl true
  def handle_node_down(node, state) do
    updated_status = Map.put(state.node_status, node, :down)

    # In a real distributed registry, we'd handle process migration here
    # For testing, we'll just track the status

    {:ok, %{state | node_status: updated_status}}
  end

  @impl true
  def start_registry(opts) do
    # For testing, just create an initial state
    init(opts)
  end

  @impl true
  def stop_registry(_reason, state) do
    # Clean up resources
    terminate(:shutdown, state)
  end

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
  def simulate_node_down(node, state) do
    handle_node_down(node, state)
  end

  @doc """
  Simulate network partition for testing.
  """
  def simulate_partition(nodes_a, nodes_b, _state) do
    # For testing, just track which nodes can't see each other
    send(self(), {:mock_partition, nodes_a, nodes_b})
    :ok
  end

  @doc """
  Get all registrations for verification.
  """
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
