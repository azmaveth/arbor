defmodule Arbor.Core.HordeRegistry do
  @moduledoc """
  Production implementation of cluster registry using Horde.Registry.
  
  This module provides distributed agent registration and discovery capabilities
  using Horde's CRDT-based registry for true cluster-wide consistency.
  
  PRODUCTION: This replaces the LocalRegistry mock for distributed operation!
  
  Features:
  - CRDT-based consistency across cluster nodes
  - Automatic conflict resolution
  - Process monitoring and cleanup
  - TTL support for temporary registrations
  - Group-based agent organization
  """
  
  use GenServer
  
  alias Arbor.Contracts.Cluster.Registry, as: RegistryContract
  
  @behaviour RegistryContract
  
  # Registry configuration
  @registry_name Arbor.Core.HordeAgentRegistry
  @supervisor_name Arbor.Core.HordeRegistrySupervisor
  @default_ttl 30_000  # 30 seconds
  
  # GenServer for TTL management
  defstruct [
    :ttl_timers,
    :group_memberships
  ]
  
  @type state :: %__MODULE__{
    ttl_timers: %{binary() => reference()},
    group_memberships: %{binary() => [binary()]}
  }
  
  # Client API - Registry Contract Implementation
  
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end
  
  # Compatibility APIs for ClusterRegistry
  
  @doc """
  Register a name with optional state parameter for compatibility.
  """
  @impl RegistryContract
  def register_name(name, pid, metadata, _state \\ nil)
  
  def register_name(name, pid, metadata, _state) when is_tuple(name) do
    # Handle {:agent, agent_id} format from ClusterRegistry
    case name do
      {:agent, agent_id} -> 
        case register_agent_name(agent_id, pid, metadata) do
          {:ok, _pid} -> :ok
          {:error, :already_registered} -> {:error, :name_taken}
          error -> error
        end
      
      _ ->
        {:error, :unsupported_name_format}
    end
  end
  
  def register_name(agent_id, pid, metadata, _state) when is_binary(agent_id) do
    # Direct agent_id format
    case register_agent_name(agent_id, pid, metadata) do
      {:ok, _pid} -> :ok
      {:error, :already_registered} -> {:error, :name_taken}
      error -> error
    end
  end
  
  @doc """
  Lookup a name with optional state parameter for compatibility.
  """
  @impl RegistryContract
  def lookup_name(name, _state \\ nil)
  
  def lookup_name(name, _state) when is_tuple(name) do
    # Handle {:agent, agent_id} format from ClusterRegistry
    case name do
      {:agent, agent_id} ->
        case lookup_agent_name(agent_id) do
          {:ok, pid, metadata} -> {:ok, {pid, metadata}}
          {:error, :not_found} -> {:error, :not_registered}
        end
      
      _ ->
        {:error, :not_registered}
    end
  end
  
  def lookup_name(agent_id, _state) when is_binary(agent_id) do
    # Direct agent_id format
    case lookup_agent_name(agent_id) do
      {:ok, pid, metadata} -> {:ok, {pid, metadata}}
      {:error, :not_found} -> {:error, :not_registered}
    end
  end
  
  @doc """
  Match pattern with optional state parameter for compatibility.
  """
  @impl RegistryContract
  def match(pattern, _state \\ nil) do
    case pattern do
      {:agent, :_} ->
        # Return all agent registrations
        agents = list_names()
        formatted = Enum.map(agents, fn {agent_id, pid, metadata} ->
          {{:agent, agent_id}, pid, metadata}
        end)
        {:ok, formatted}
      
      _ ->
        {:ok, []}
    end
  end
  
  # Core Horde Registry Implementation
  
  def register_agent_name(agent_id, pid, metadata \\ %{}) do
    case Horde.Registry.register(@registry_name, agent_id, metadata) do
      {:ok, _owner} -> 
        # Monitor the process for automatic cleanup
        GenServer.cast(__MODULE__, {:monitor_process, agent_id, pid})
        {:ok, pid}
      
      {:error, {:already_registered, existing_pid}} ->
        if Process.alive?(existing_pid) do
          {:error, :already_registered}
        else
          # Process died but registry entry still exists, try to re-register
          Horde.Registry.unregister(@registry_name, agent_id)
          register_agent_name(agent_id, pid, metadata)
        end
      
      error -> error
    end
  end
  
  def register_name_with_ttl(agent_id, pid, metadata, ttl) do
    case register_agent_name(agent_id, pid, metadata) do
      {:ok, registered_pid} ->
        # Set up TTL timer
        GenServer.cast(__MODULE__, {:set_ttl, agent_id, ttl})
        {:ok, registered_pid}
      
      error -> error
    end
  end
  
  @impl RegistryContract
  def unregister_name(name, _state \\ nil)
  
  def unregister_name(name, _state) when is_tuple(name) do
    case name do
      {:agent, agent_id} -> unregister_agent_name(agent_id)
      _ -> {:error, :unsupported_name_format}
    end
  end
  
  def unregister_name(agent_id, _state) when is_binary(agent_id) do
    unregister_agent_name(agent_id)
  end
  
  def unregister_agent_name(agent_id) do
    case Horde.Registry.unregister(@registry_name, agent_id) do
      :ok -> 
        # Clean up TTL timer and group memberships
        GenServer.cast(__MODULE__, {:cleanup_agent, agent_id})
        :ok
      
      error -> error
    end
  end
  
  def lookup_agent_name(agent_id) do
    case Horde.Registry.lookup(@registry_name, agent_id) do
      [{pid, metadata}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid, metadata}
        else
          # Process died, clean up registry
          Horde.Registry.unregister(@registry_name, agent_id)
          {:error, :not_found}
        end
      
      [] -> {:error, :not_found}
      
      multiple when is_list(multiple) ->
        # Handle multiple registrations (shouldn't happen normally)
        alive_entries = Enum.filter(multiple, fn {pid, _meta} -> Process.alive?(pid) end)
        case alive_entries do
          [{pid, metadata}] -> {:ok, pid, metadata}
          [] -> {:error, :not_found}
          _ -> {:error, :multiple_registrations}
        end
    end
  end
  
  def list_names() do
    @registry_name
    |> Horde.Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.filter(fn {_key, pid, _meta} -> Process.alive?(pid) end)
    |> Enum.map(fn {agent_id, pid, metadata} -> {agent_id, pid, metadata} end)
  end
  
  def list_names_by_pattern(pattern) do
    # Convert glob pattern to regex for matching
    regex_pattern = pattern
                   |> String.replace("*", ".*")
                   |> String.replace("?", ".")
                   |> then(&("^" <> &1 <> "$"))
    
    case Regex.compile(regex_pattern) do
      {:ok, regex} ->
        list_names()
        |> Enum.filter(fn {agent_id, _pid, _meta} -> 
          Regex.match?(regex, agent_id)
        end)
      
      {:error, _} -> []
    end
  end
  
  # Add the list_by_pattern function expected by ClusterRegistry
  def list_by_pattern(pattern, _state \\ nil) do
    {:ok, list_names_by_pattern(pattern)}
  end
  
  def count_names() do
    @registry_name
    |> Horde.Registry.count()
  end
  
  # Group management
  
  @impl RegistryContract
  def register_group(group_name, agent_id) do
    GenServer.call(__MODULE__, {:register_group, group_name, agent_id})
  end
  
  @impl RegistryContract
  def unregister_group(group_name, agent_id) do
    GenServer.call(__MODULE__, {:unregister_group, group_name, agent_id})
  end
  
  @impl RegistryContract
  def list_group_members(group_name) do
    GenServer.call(__MODULE__, {:list_group_members, group_name})
  end
  
  # Note: list_group_members/2 removed to avoid conflict with list_group_members/1
  # The /1 version handles both cases since _state parameter is optional and ignored
  
  @impl RegistryContract
  def list_agent_groups(agent_id) do
    GenServer.call(__MODULE__, {:list_agent_groups, agent_id})
  end
  
  # Additional compatibility methods for LocalRegistry interface
  
  @impl RegistryContract
  def update_metadata(name, metadata, _state \\ nil) do
    case name do
      {:agent, agent_id} ->
        # In Horde, we need to re-register to update metadata
        case lookup_agent_name(agent_id) do
          {:ok, pid, _old_metadata} ->
            # Unregister and re-register with new metadata
            case unregister_agent_name(agent_id) do
              :ok ->
                case register_agent_name(agent_id, pid, metadata) do
                  {:ok, _} -> :ok
                  error -> error
                end
              error -> error
            end
          
          {:error, :not_found} ->
            {:error, :not_registered}
        end
      
      _ ->
        {:error, :unsupported_name_format}
    end
  end
  
  @impl RegistryContract
  def register_group(group_name, agent_pid, metadata, _state \\ nil) do
    # For compatibility, delegate to group management functions
    case group_name do
      {:agent_group, group_id} ->
        # Use our internal group management
        GenServer.call(__MODULE__, {:register_agent_group, group_id, agent_pid, metadata})
      
      _ ->
        {:error, :unsupported_group_format}
    end
  end
  
  @impl RegistryContract
  def lookup_group(group_name, _state \\ nil) do
    case group_name do
      {:agent_group, group_id} ->
        # Return list of {pid, metadata} tuples
        case GenServer.call(__MODULE__, {:list_group_members, group_id}) do
          {:ok, agent_ids} ->
            members = Enum.map(agent_ids, fn agent_id ->
              case lookup_agent_name(agent_id) do
                {:ok, pid, metadata} -> {pid, metadata}
                _ -> nil
              end
            end)
            |> Enum.reject(&is_nil/1)
            
            if members == [] do
              {:error, :group_not_found}
            else
              {:ok, members}
            end
          
          error -> error
        end
      
      _ ->
        {:error, :unsupported_group_format}
    end
  end
  
  @impl RegistryContract
  def health_check(_state \\ nil) do
    registry_status = get_registry_status()
    
    {:ok, %{
      node_count: length(registry_status.members),
      nodes: registry_status.members,
      sync_status: registry_status.status
    }}
  end
  
  # Process monitoring
  
  def monitor_agent(agent_id, _monitor_pid) do
    case lookup_name(agent_id) do
      {:ok, {target_pid, _metadata}} ->
        monitor_ref = Process.monitor(target_pid)
        {:ok, monitor_ref}
      
      error -> error
    end
  end
  
  @impl RegistryContract
  def demonitor_agent(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end
  
  # Registry management
  
  @doc """
  Start the Horde registry supervisor.
  
  This should be called during application startup to initialize
  the distributed registry infrastructure.
  """
  @spec start_registry() :: {:ok, pid()} | {:error, term()}
  def start_registry() do
    children = [
      {Horde.Registry, [
        name: @registry_name,
        keys: :unique,
        members: :auto,
        delta_crdt_options: [sync_interval: 100]
      ]},
      {__MODULE__, []}
    ]
    
    Supervisor.start_link(children, strategy: :one_for_one, name: @supervisor_name)
  end
  
  @doc """
  Join a node to the registry cluster.
  
  This should be called when a new node joins the cluster to ensure
  the registry is properly distributed.
  """
  @spec join_registry(node()) :: :ok
  def join_registry(node) do
    Horde.Cluster.set_members(@registry_name, [node() | [node]])
    :ok
  end
  
  @doc """
  Leave the registry cluster.
  
  This should be called when a node is leaving the cluster gracefully.
  """
  @spec leave_registry(node()) :: :ok
  def leave_registry(node) do
    current_members = Horde.Cluster.members(@registry_name)
    new_members = List.delete(current_members, node)
    Horde.Cluster.set_members(@registry_name, new_members)
    :ok
  end
  
  @doc """
  Get registry cluster status.
  
  Returns information about the current registry cluster including
  member nodes and registry statistics.
  """
  @spec get_registry_status() :: %{
    members: [node()],
    count: non_neg_integer(),
    status: :healthy | :degraded | :critical
  }
  def get_registry_status() do
    # In test mode, return mock status
    case Application.get_env(:arbor_core, :registry_impl, :auto) do
      :mock ->
        %{
          members: [node()],
          count: 0,
          status: :healthy
        }
      _ ->
        members = Horde.Cluster.members(@registry_name)
        count = Horde.Registry.count(@registry_name)
        
        status = cond do
          length(members) == 0 -> :critical
          length(members) == 1 -> :degraded
          true -> :healthy
        end
        
        %{
          members: members,
          count: count,
          status: status
        }
    end
  end
  
  # Missing Registry contract implementations
  
  @impl RegistryContract
  def count(_state) do
    {:ok, Horde.Registry.count(@registry_name)}
  end
  
  @impl RegistryContract
  def monitor(name, _state) do
    case name do
      {:agent, agent_id} ->
        case lookup_agent_name(agent_id) do
          {:ok, pid, _metadata} ->
            ref = Process.monitor(pid)
            {:ok, ref}
          {:error, :not_found} ->
            {:error, :not_registered}
        end
      _ ->
        {:error, :not_registered}
    end
  end
  
  @impl RegistryContract
  def register_with_ttl(name, pid, ttl, metadata, _state) do
    case name do
      {:agent, agent_id} ->
        register_name_with_ttl(agent_id, pid, metadata, ttl)
      _ ->
        {:error, :unsupported_name_format}
    end
  end
  
  @impl RegistryContract
  def unregister_group(group, pid, _state) do
    # For group-based unregistration (different from unregister_group/2)
    case group do
      {:agent_group, group_id} ->
        # Find agent_id for this pid
        agents = list_names()
        agent_id = Enum.find_value(agents, fn {id, p, _meta} ->
          if p == pid, do: id, else: nil
        end)
        
        case agent_id do
          nil -> {:error, :not_registered}
          agent_id -> 
            GenServer.call(__MODULE__, {:unregister_group, group_id, agent_id})
        end
      _ ->
        {:error, :unsupported_group_format}
    end
  end
  
  @impl RegistryContract
  def handle_node_up(node, state) do
    # Join the new node to our registry cluster
    join_registry(node)
    {:ok, state}
  end
  
  @impl RegistryContract
  def handle_node_down(node, state) do
    # Remove the node from our registry cluster
    leave_registry(node)
    {:ok, state}
  end
  
  @impl RegistryContract
  def start_registry(_opts) do
    # For HordeRegistry, the component initialization is handled during application startup
    # This callback provides the initial state for the contract
    {:ok, nil}
  end

  @impl RegistryContract
  def stop_registry(_reason, _state) do
    :ok
  end
  
  # Note: Registry contract init/1 renamed to start_registry/1 to avoid conflict with GenServer init/1
  # GenServer callbacks for TTL and group management
  
  @impl GenServer
  def init(_opts) do
    state = %__MODULE__{
      ttl_timers: %{},
      group_memberships: %{}
    }
    
    {:ok, state}
  end
  
  @impl GenServer
  def handle_call({:register_group, group_name, agent_id}, _from, state) do
    # Verify agent exists
    case lookup_name(agent_id) do
      {:ok, {_pid, _metadata}} ->
        current_groups = Map.get(state.group_memberships, agent_id, [])
        
        if group_name in current_groups do
          {:reply, {:error, :already_in_group}, state}
        else
          updated_groups = [group_name | current_groups]
          updated_memberships = Map.put(state.group_memberships, agent_id, updated_groups)
          new_state = %{state | group_memberships: updated_memberships}
          {:reply, :ok, new_state}
        end
      
      error ->
        {:reply, error, state}
    end
  end
  
  @impl GenServer
  def handle_call({:unregister_group, group_name, agent_id}, _from, state) do
    current_groups = Map.get(state.group_memberships, agent_id, [])
    updated_groups = List.delete(current_groups, group_name)
    
    updated_memberships = if updated_groups == [] do
      Map.delete(state.group_memberships, agent_id)
    else
      Map.put(state.group_memberships, agent_id, updated_groups)
    end
    
    new_state = %{state | group_memberships: updated_memberships}
    {:reply, :ok, new_state}
  end
  
  @impl GenServer
  def handle_call({:list_group_members, group_name}, _from, state) do
    members = 
      state.group_memberships
      |> Enum.filter(fn {_agent_id, groups} -> group_name in groups end)
      |> Enum.map(fn {agent_id, _groups} -> agent_id end)
      |> Enum.filter(fn agent_id ->
        # Only include agents that are still registered and alive
        case lookup_name(agent_id) do
          {:ok, {_pid, _metadata}} -> true
          _ -> false
        end
      end)
    
    {:reply, {:ok, members}, state}
  end
  
  @impl GenServer
  def handle_call({:list_agent_groups, agent_id}, _from, state) do
    groups = Map.get(state.group_memberships, agent_id, [])
    {:reply, {:ok, groups}, state}
  end
  
  @impl GenServer
  def handle_call({:register_agent_group, group_id, agent_pid, metadata}, _from, state) do
    # Find agent_id for this pid from registry
    agents = list_names()
    agent_id = Enum.find_value(agents, fn {id, pid, _meta} ->
      if pid == agent_pid, do: id, else: nil
    end)
    
    case agent_id do
      nil ->
        {:reply, {:error, :agent_not_registered}, state}
      
      agent_id ->
        current_groups = Map.get(state.group_memberships, agent_id, [])
        
        if group_id in current_groups do
          {:reply, {:error, :already_in_group}, state}
        else
          updated_groups = [group_id | current_groups]
          updated_memberships = Map.put(state.group_memberships, agent_id, updated_groups)
          new_state = %{state | group_memberships: updated_memberships}
          {:reply, :ok, new_state}
        end
    end
  end
  
  @impl GenServer
  def handle_cast({:monitor_process, agent_id, pid}, state) do
    Process.monitor(pid)
    {:noreply, state}
  end
  
  @impl GenServer
  def handle_cast({:set_ttl, agent_id, ttl}, state) do
    # Cancel existing timer if any
    case Map.get(state.ttl_timers, agent_id) do
      nil -> :ok
      timer_ref -> Process.cancel_timer(timer_ref)
    end
    
    # Set new timer
    timer_ref = Process.send_after(self(), {:ttl_expired, agent_id}, ttl)
    updated_timers = Map.put(state.ttl_timers, agent_id, timer_ref)
    new_state = %{state | ttl_timers: updated_timers}
    
    {:noreply, new_state}
  end
  
  @impl GenServer
  def handle_cast({:cleanup_agent, agent_id}, state) do
    # Clean up TTL timer
    updated_timers = case Map.get(state.ttl_timers, agent_id) do
      nil -> state.ttl_timers
      timer_ref -> 
        Process.cancel_timer(timer_ref)
        Map.delete(state.ttl_timers, agent_id)
    end
    
    # Clean up group memberships
    updated_memberships = Map.delete(state.group_memberships, agent_id)
    
    new_state = %{state | ttl_timers: updated_timers, group_memberships: updated_memberships}
    {:noreply, new_state}
  end
  
  @impl GenServer
  def handle_info({:ttl_expired, agent_id}, state) do
    # Unregister agent due to TTL expiration
    unregister_name(agent_id)
    
    # Clean up timer tracking
    updated_timers = Map.delete(state.ttl_timers, agent_id)
    new_state = %{state | ttl_timers: updated_timers}
    
    {:noreply, new_state}
  end
  
  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Handle process death - find and unregister the agent
    @registry_name
    |> Horde.Registry.select([{{:"$1", pid, :"$3"}, [], [:"$1"]}])
    |> Enum.each(&unregister_name/1)
    
    {:noreply, state}
  end
  
  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end