defmodule Arbor.Core.HordeRegistry do
  @moduledoc """
  Distributed registry implementation using Horde.Registry directly.

  This is NOT a GenServer - it's a module that provides functions to interact
  with the distributed Horde.Registry. All state is maintained in Horde.Registry
  itself, making it truly distributed across the cluster.

  Key design decisions:
  - No local state (no GenServer, no ETS)
  - All data stored in Horde.Registry CRDT
  - TTL functionality temporarily disabled (needs distributed timer solution)
  - Group functionality simplified to use registry entries

  Registry entry format:
  - Agent entries: {agent_id, {pid, metadata}}
  - Group entries: {{:group, group_name, agent_id}, true}
  """

  alias Arbor.Contracts.Cluster.Registry, as: RegistryContract

  require Logger

  @behaviour RegistryContract

  # Registry name - must match what's started in supervisor
  @registry_name Arbor.Core.HordeAgentRegistry

  # Registry Contract Implementation

  @impl RegistryContract
  def register_name(name, pid, metadata, _state \\ nil) when is_pid(pid) do
    agent_id = extract_agent_id(name)

    # Store pid and metadata as a tuple value
    value = {pid, metadata}

    # Register in Horde - this creates a distributed entry
    case Horde.Registry.register(@registry_name, agent_id, value) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, _}} ->
        # If the name is already taken, we return an error.
        # Stale entries are cleaned up by the AgentReconciler to avoid race conditions.
        {:error, :name_taken}
    end
  end

  @impl RegistryContract
  def lookup_name(name, _state \\ nil) do
    agent_id = extract_agent_id(name)

    # Use select instead of lookup which doesn't exist in Horde v0.9.1
    # Pattern ignores the registering PID (second element) and extracts the stored value
    case Horde.Registry.select(@registry_name, [{{agent_id, :_, :"$1"}, [], [:"$1"]}]) do
      [] ->
        {:error, :not_registered}

      [value] when is_tuple(value) and tuple_size(value) == 2 ->
        {pid, metadata} = value

        if Process.alive?(pid) do
          {:ok, {pid, metadata}}
        else
          # The process is dead, so we treat it as not registered.
          # The AgentReconciler is responsible for cleaning up the stale entry from the registry.
          {:error, :not_registered}
        end

      _ ->
        {:error, :not_registered}
    end
  end

  @impl RegistryContract
  def unregister_name(name, _state \\ nil) do
    agent_id = extract_agent_id(name)

    # Unregister from Horde
    Horde.Registry.unregister(@registry_name, agent_id)

    # Clean up any group memberships
    cleanup_agent_groups(agent_id)

    :ok
  end

  @impl RegistryContract
  def register_with_ttl(_name, _pid, _ttl, _metadata, _state) do
    # TTL functionality temporarily disabled
    # Needs distributed timer solution (e.g., using Process.send_after with node tracking)
    #
    # TODO: To implement TTL support:
    # 1. Create a distributed timer service using Horde.DynamicSupervisor to manage timer processes
    # 2. Timer processes should monitor the registered process and unregister after TTL expires
    # 3. Handle node failures by redistributing timer processes across the cluster
    # 4. Consider using a CRDT-based timer for better consistency
    #
    # This is a known limitation that should be addressed if temporary registrations are needed.
    {:error, :ttl_not_implemented}
  end

  @impl RegistryContract
  def update_metadata(name, new_metadata, _state \\ nil) do
    case lookup_name(name) do
      {:ok, {pid, old_metadata}} ->
        # Simply re-register with the merged metadata. Horde will handle the update.
        merged_metadata = Map.merge(old_metadata, new_metadata)
        register_name(name, pid, merged_metadata)

      error ->
        error
    end
  end

  @impl RegistryContract
  def register_group(group_name, pid, metadata, _state \\ nil) do
    # TODO: Group registrations store a PID and can become stale if an agent is
    # restarted. A robust solution would involve storing group membership in the
    # agent's spec and having the reconciler handle re-registration.

    # Find agent ID for this PID
    case find_agent_by_pid(pid) do
      {:ok, agent_id} ->
        group_key = {:group, extract_group_id(group_name), agent_id}

        # Register group membership
        case Horde.Registry.register(@registry_name, group_key, {pid, metadata}) do
          {:ok, _} -> :ok
          {:error, {:already_registered, _}} -> {:error, :already_in_group}
        end

      _ ->
        {:error, :agent_not_registered}
    end
  end

  @impl RegistryContract
  def unregister_group(group_name, pid, _state) do
    case find_agent_by_pid(pid) do
      {:ok, agent_id} ->
        group_key = {:group, extract_group_id(group_name), agent_id}
        Horde.Registry.unregister(@registry_name, group_key)
        :ok

      _ ->
        {:error, :not_registered}
    end
  end

  @impl RegistryContract
  def lookup_group(group_name, _state \\ nil) do
    group_id = extract_group_id(group_name)

    # TODO (SCALABILITY): This is a full registry scan and will not scale.
    # To optimize, consider:
    # 1. Maintaining a separate ETS table mapping `group_id` to a set of `agent_id`s.
    # 2. Restructuring the registry data to have a single key per group, e.g.,
    #    `{:group, group_id}` with a value being a list/map of members. This
    #    would require careful handling of concurrent updates.
    # 3. Using a dedicated sidecar process (e.g., GenServer) to manage group indexes.
    # Find all group members by looking up keys that match {:group, group_id, _}
    all_entries =
      Horde.Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])

    members =
      all_entries
      |> Enum.filter(fn
        {{:group, ^group_id, _agent_id}, _value} -> true
        _ -> false
      end)
      |> Enum.map(fn {_key, {pid, metadata}} -> {pid, metadata} end)

    if members == [] do
      {:error, :group_not_found}
    else
      {:ok, members}
    end
  end

  @impl RegistryContract
  def match(pattern, _state \\ nil) do
    # TODO (SCALABILITY): This performs a full registry scan and will not scale.
    # To optimize, consider using a more specific `Horde.Registry.select` pattern if
    # possible, or maintaining a separate index (e.g., in an ETS table) for agents.
    case pattern do
      {:agent, :_} ->
        # Get all entries and filter for agent registrations
        all_entries =
          Horde.Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])

        agents =
          all_entries
          |> Enum.filter(fn
            {agent_id, {_pid, _metadata}} when is_binary(agent_id) -> true
            _ -> false
          end)
          |> Enum.map(fn {agent_id, {pid, metadata}} ->
            {{:agent, agent_id}, pid, metadata}
          end)

        {:ok, agents}

      _ ->
        {:ok, []}
    end
  end

  @impl RegistryContract
  def count(_state) do
    # TODO (SCALABILITY): This is a full registry scan and will not scale.
    # To optimize, consider maintaining a distributed counter (e.g., using Horde.Counter)
    # that is incremented/decremented when agents are registered/unregistered.
    # Count only agent entries (not groups)
    all_entries = Horde.Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])

    agent_count =
      Enum.count(all_entries, fn
        key when is_binary(key) -> true
        _ -> false
      end)

    {:ok, agent_count}
  end

  @impl RegistryContract
  def monitor(name, _state) do
    case lookup_name(name) do
      {:ok, {pid, _metadata}} ->
        ref = Process.monitor(pid)
        {:ok, ref}

      error ->
        error
    end
  end

  @impl RegistryContract
  def health_check(_state \\ nil) do
    members = Horde.Cluster.members(@registry_name)
    {:ok, agent_count} = count(nil)

    status =
      cond do
        Enum.empty?(members) -> :critical
        length(members) == 1 -> :degraded
        true -> :healthy
      end

    {:ok,
     %{
       node_count: length(members),
       registration_count: agent_count,
       nodes: members,
       sync_status: status
     }}
  end

  @impl RegistryContract
  def handle_node_up(_node, state) do
    # Horde handles this automatically
    {:ok, state}
  end

  @impl RegistryContract
  def handle_node_down(_node, state) do
    # Horde handles this automatically
    {:ok, state}
  end

  @impl RegistryContract
  def start_registry(_opts) do
    # Registry should be started by supervisor, not by this module
    {:ok, nil}
  end

  @impl RegistryContract
  def stop_registry(_reason, _state) do
    :ok
  end

  # Compatibility functions for existing code

  @spec register_agent_name(String.t(), pid(), map()) :: {:ok, pid()} | {:error, atom()}
  def register_agent_name(agent_id, pid, metadata \\ %{}) do
    case register_name(agent_id, pid, metadata) do
      :ok -> {:ok, pid}
      error -> error
    end
  end

  @spec lookup_agent_name(String.t()) :: {:ok, pid(), map()} | {:error, atom()}
  def lookup_agent_name(agent_id) do
    case lookup_name(agent_id) do
      {:ok, {pid, metadata}} -> {:ok, pid, metadata}
      error -> error
    end
  end

  @doc """
  Looks up an agent name without checking if the process is alive.

  This is intended for system-level tools like the AgentReconciler that
  need to detect and clean up stale entries.
  """
  @spec lookup_agent_name_raw(String.t()) :: {:ok, pid(), map()} | {:error, atom()}
  def lookup_agent_name_raw(agent_id) do
    case lookup_name_raw(agent_id) do
      {:ok, {pid, metadata}} -> {:ok, pid, metadata}
      error -> error
    end
  end

  @spec unregister_agent_name(String.t()) :: :ok | {:error, atom()}
  def unregister_agent_name(agent_id) do
    unregister_name(agent_id)
  end

  @spec list_names() :: [{String.t(), pid(), map()}]
  def list_names() do
    # TODO (SCALABILITY): This is a full registry scan and will not scale.
    # This function should be used with caution in production. For scalable listing,
    # consider building and maintaining a separate index of agent names.
    all_entries =
      Horde.Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])

    Enum.flat_map(all_entries, fn
      {agent_id, {pid, metadata}} when is_binary(agent_id) ->
        [{agent_id, pid, metadata}]

      _ ->
        []
    end)
  end

  @spec get_registry_status() :: map()
  def get_registry_status do
    members = Horde.Cluster.members(@registry_name)
    {:ok, count} = count(nil)

    status =
      cond do
        Enum.empty?(members) -> :critical
        length(members) == 1 -> :degraded
        true -> :healthy
      end

    %{
      members: members,
      count: count,
      status: status
    }
  end

  # Group management helpers

  @spec register_group(String.t(), String.t()) :: :ok | {:error, atom()}
  def register_group(group_name, agent_id) do
    # Look up the agent to get its PID
    case lookup_name(agent_id) do
      {:ok, {pid, _metadata}} ->
        register_group(group_name, pid, %{})

      error ->
        error
    end
  end

  @spec unregister_group(String.t(), String.t()) :: :ok | {:error, atom()}
  def unregister_group(group_name, agent_id) do
    # Look up the agent to get its PID
    case lookup_name(agent_id) do
      {:ok, {pid, _metadata}} ->
        unregister_group(group_name, pid, nil)

      error ->
        error
    end
  end

  @spec list_group_members(String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def list_group_members(group_name) do
    case lookup_group_with_agent_ids(group_name) do
      {:ok, members} ->
        # Extract agent IDs directly from the efficient lookup
        agent_ids = Enum.map(members, fn {agent_id, _pid, _metadata} -> agent_id end)
        {:ok, agent_ids}

      error ->
        error
    end
  end

  # Efficient internal function that preserves agent_id from registry keys
  defp lookup_group_with_agent_ids(group_name) do
    group_id = extract_group_id(group_name)

    # Scan registry once and preserve agent_id from the key structure
    all_entries =
      Horde.Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])

    members =
      all_entries
      |> Enum.filter(fn
        {{:group, ^group_id, _agent_id}, _value} -> true
        _ -> false
      end)
      |> Enum.map(fn {{:group, _group_id, agent_id}, {pid, metadata}} ->
        # Return {agent_id, pid, metadata} - preserving all needed info
        {agent_id, pid, metadata}
      end)

    if members == [] do
      {:error, :group_not_found}
    else
      {:ok, members}
    end
  end

  @spec list_agent_groups(String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def list_agent_groups(agent_id) do
    # TODO (SCALABILITY): This is a full registry scan and will not scale.
    # To optimize, consider storing an agent's group memberships within its own
    # metadata, allowing for a direct lookup of the agent's entry instead of a scan.
    # Find all group memberships for this agent
    all_entries =
      Horde.Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])

    groups =
      all_entries
      |> Enum.filter(fn
        {{:group, _group_name, ^agent_id}, _value} -> true
        _ -> false
      end)
      |> Enum.map(fn {{:group, group_name, _}, _} -> group_name end)

    {:ok, groups}
  end

  # Private functions

  defp extract_agent_id({:agent, agent_id}), do: agent_id
  defp extract_agent_id(agent_id) when is_binary(agent_id), do: agent_id

  defp extract_group_id({:agent_group, group_id}), do: group_id
  defp extract_group_id(group_id) when is_binary(group_id), do: group_id

  defp lookup_name_raw(name) do
    agent_id = extract_agent_id(name)

    # Use select instead of lookup which doesn't exist in Horde v0.9.1
    # Pattern ignores the registering PID (second element) and extracts the stored value
    case Horde.Registry.select(@registry_name, [{{agent_id, :_, :"$1"}, [], [:"$1"]}]) do
      [] ->
        {:error, :not_registered}

      [value] when is_tuple(value) and tuple_size(value) == 2 ->
        {:ok, value}

      _ ->
        {:error, :not_registered}
    end
  end

  defp find_agent_by_pid(target_pid) do
    # TODO (SCALABILITY): This is a full registry scan and will not scale.
    # To optimize, maintain a reverse index (e.g., in another Horde.Registry or ETS table)
    # that maps PID to agent_id. This would provide a direct lookup instead of a scan.
    all_entries =
      Horde.Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])

    result =
      Enum.find(all_entries, fn
        {agent_id, {pid, _metadata}} when is_binary(agent_id) ->
          pid == target_pid

        _ ->
          false
      end)

    case result do
      {agent_id, _} -> {:ok, agent_id}
      _ -> {:error, :not_found}
    end
  end

  defp cleanup_agent_groups(agent_id) do
    # TODO (SCALABILITY): This is a full registry scan and will not scale.
    # This is called when an agent is unregistered and must be correct, but it will
    # become a performance issue. A better approach would be to fetch the agent's
    # group memberships from its metadata and unregister them directly.
    # Find and unregister all group memberships
    all_entries = Horde.Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])

    all_entries
    |> Enum.filter(fn
      {:group, _group_name, ^agent_id} -> true
      _ -> false
    end)
    |> Enum.each(&Horde.Registry.unregister(@registry_name, &1))
  end

  # Cluster management functions for ClusterManager

  @doc """
  Join a node to the registry cluster.
  """
  @spec join_registry(node()) :: :ok
  def join_registry(node) do
    Horde.Cluster.set_members(@registry_name, [node() | [node]])
    :ok
  end

  @doc """
  Remove a node from the registry cluster.
  """
  @spec leave_registry(node()) :: :ok
  def leave_registry(node) do
    current_members = Horde.Cluster.members(@registry_name)
    new_members = List.delete(current_members, node)
    Horde.Cluster.set_members(@registry_name, new_members)
    :ok
  end

  @doc """
  List agent registrations matching a pattern.
  """
  @spec list_by_pattern(String.t(), any()) :: [{String.t(), pid(), map()}]
  def list_by_pattern(pattern, _state) do
    # Convert pattern to regex for flexible matching
    regex_pattern =
      ("^" <> String.replace(pattern, "*", ".*") <> "$")
      |> Regex.compile!()

    @registry_name
    |> Horde.Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.filter(fn
      {agent_id, pid, _metadata} when is_binary(agent_id) and is_pid(pid) ->
        Regex.match?(regex_pattern, agent_id)

      _ ->
        false
    end)
    |> Enum.map(fn {agent_id, pid, metadata} -> {agent_id, pid, metadata} end)
  end

  # Private helper functions
end
