defmodule Arbor.Test.Mocks.LocalRegistry do
  @moduledoc """
  MOCK implementation of cluster registry for single-node testing.

  This provides a local-only implementation of the Arbor.Contracts.Cluster.Registry
  behaviour for unit testing distributed logic without requiring actual clustering.

  IMPORTANT: This is a MOCK - replace with Horde for distributed operation!
  """

  @behaviour Arbor.Contracts.Cluster.Registry

  use Agent

  defstruct [
    :names,
    :groups,
    :monitors
  ]

  @type state :: %__MODULE__{
          names: %{any() => {pid(), map()}},
          groups: %{any() => [{pid(), map()}]},
          monitors: %{reference() => any()}
        }

  # Client API

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(
      fn ->
        %__MODULE__{
          names: %{},
          groups: %{},
          monitors: %{}
        }
      end,
      name: __MODULE__
    )
  end

  # Internal function for Agent initialization, not part of behavior
  @spec init(any()) :: {:ok, state()}
  def init(_opts) do
    state = %__MODULE__{
      names: %{},
      groups: %{},
      monitors: %{}
    }

    {:ok, state}
  end

  @spec clear() :: :ok
  def clear do
    Agent.update(__MODULE__, fn _state ->
      %__MODULE__{
        names: %{},
        groups: %{},
        monitors: %{}
      }
    end)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def start_registry(_opts) do
    state = %__MODULE__{
      names: %{},
      groups: %{},
      monitors: %{}
    }

    {:ok, state}
  end

  @impl Arbor.Contracts.Cluster.Registry
  def stop_registry(_reason, _state) do
    :ok
  end

  @impl Arbor.Contracts.Cluster.Registry
  def register_name(name, pid, metadata, _state) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.names, name) do
        nil ->
          updated_names = Map.put(state.names, name, {pid, metadata})
          updated_state = %{state | names: updated_names}
          {:ok, updated_state}

        _existing ->
          {{:error, :name_taken}, state}
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def register_group(group, pid, metadata, _state) do
    Agent.update(__MODULE__, fn state ->
      current_members = Map.get(state.groups, group, [])
      updated_members = [{pid, metadata} | current_members]
      updated_groups = Map.put(state.groups, group, updated_members)
      %{state | groups: updated_groups}
    end)

    :ok
  end

  @impl Arbor.Contracts.Cluster.Registry
  def unregister_name(name, _state) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.names, name) do
        nil ->
          {{:error, :not_registered}, state}

        _existing ->
          updated_names = Map.delete(state.names, name)
          updated_state = %{state | names: updated_names}
          {:ok, updated_state}
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def unregister_group(group, pid, _state) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.groups, group) do
        nil ->
          {{:error, :not_registered}, state}

        members ->
          updated_members = Enum.reject(members, fn {member_pid, _} -> member_pid == pid end)

          updated_groups =
            if updated_members == [] do
              Map.delete(state.groups, group)
            else
              Map.put(state.groups, group, updated_members)
            end

          updated_state = %{state | groups: updated_groups}
          {:ok, updated_state}
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def lookup_name(name, _state) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.names, name) do
        nil ->
          {:error, :not_registered}

        {pid, metadata} ->
          {:ok, {pid, metadata}}
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def lookup_group(group, _state) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.groups, group) do
        nil ->
          {:error, :group_not_found}

        [] ->
          {:error, :group_not_found}

        members ->
          {:ok, members}
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def update_metadata(name, metadata, _state) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.names, name) do
        nil ->
          {{:error, :not_registered}, state}

        {pid, _old_metadata} ->
          updated_names = Map.put(state.names, name, {pid, metadata})
          updated_state = %{state | names: updated_names}
          {:ok, updated_state}
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def register_with_ttl(name, pid, _ttl, metadata, state) do
    # For unit tests, just register normally
    # Real implementation would set up TTL expiration
    register_name(name, pid, metadata, state)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def match(pattern, _state) do
    Agent.get(__MODULE__, fn state ->
      matches =
        state.names
        |> Enum.filter(fn {name, _} -> matches_pattern?(name, pattern) end)
        |> Enum.map(fn {name, {pid, metadata}} -> {name, pid, metadata} end)

      {:ok, matches}
    end)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def count(_state) do
    Agent.get(__MODULE__, fn state ->
      {:ok, map_size(state.names)}
    end)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def monitor(name, _state) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.names, name) do
        nil ->
          {{:error, :not_registered}, state}

        {_pid, _metadata} ->
          ref = make_ref()
          updated_monitors = Map.put(state.monitors, ref, name)
          updated_state = %{state | monitors: updated_monitors}
          {{:ok, ref}, updated_state}
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def health_check(_state) do
    Agent.get(__MODULE__, fn state ->
      health = %{
        # Single node for mock
        node_count: 1,
        registration_count: map_size(state.names),
        # No conflicts in single node
        conflict_count: 0,
        nodes: [node()],
        sync_status: :healthy
      }

      {:ok, health}
    end)
  end

  @impl Arbor.Contracts.Cluster.Registry
  def handle_node_up(_node, state) do
    # Mock: No-op for single node
    {:ok, state}
  end

  @impl Arbor.Contracts.Cluster.Registry
  def handle_node_down(_node, state) do
    # Mock: No-op for single node
    {:ok, state}
  end

  # Additional methods for ClusterRegistry compatibility

  @spec register_group(String.t(), String.t(), any()) :: :ok
  def register_group(group_name, agent_id, _state \\ nil) do
    Agent.update(__MODULE__, fn state ->
      current_members = Map.get(state.groups, group_name, [])
      updated_members = [agent_id | current_members]
      updated_groups = Map.put(state.groups, group_name, updated_members)
      %{state | groups: updated_groups}
    end)

    :ok
  end

  @spec list_group_members(String.t(), any()) :: {:ok, [String.t()]}
  def list_group_members(group_name, _state \\ nil) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.groups, group_name) do
        nil ->
          {:ok, []}

        members when is_list(members) ->
          # Handle both formats: just IDs or {pid, metadata} tuples
          agent_ids =
            members
            |> Enum.map(fn
              # Skip tuple format
              {_pid, _metadata} -> nil
              agent_id when is_binary(agent_id) -> agent_id
              _ -> nil
            end)
            |> Enum.reject(&is_nil/1)

          {:ok, agent_ids}
      end
    end)
  end

  @spec list_by_pattern(String.t(), any()) :: [{String.t(), pid(), map()}]
  def list_by_pattern(pattern, _state \\ nil) do
    Agent.get(__MODULE__, fn state ->
      regex =
        pattern
        |> String.replace("*", ".*")
        |> Regex.compile!()

      matches =
        state.names
        |> Enum.filter(fn
          {{:agent, agent_id}, _} -> Regex.match?(regex, agent_id)
          _ -> false
        end)
        |> Enum.map(fn {{:agent, agent_id}, {pid, metadata}} ->
          {agent_id, pid, metadata}
        end)

      {:ok, matches}
    end)
  end

  # Helper functions

  defp matches_pattern?(name, pattern) do
    case {name, pattern} do
      {{type, _id}, {type, :_}} -> true
      {name, name} -> true
      _ -> false
    end
  end
end
