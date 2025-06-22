defmodule Arbor.Core.ClusterRegistry do
  @moduledoc """
  Distributed agent registry using Horde for cluster-wide registration.

  This module provides a consistent interface for agent registration and discovery
  across the Arbor cluster. It uses Horde for the distributed implementation but
  can fall back to local-only implementation for testing.

  ## Usage

  Agents are registered with unique IDs and can be discovered cluster-wide:

      # Register an agent
      ClusterRegistry.register_agent("agent-123", agent_pid, %{type: :llm_agent})

      # Look up an agent anywhere in the cluster
      {:ok, agent_pid} = ClusterRegistry.lookup_agent("agent-123")

      # List all agents of a specific type
      {:ok, agents} = ClusterRegistry.list_agents_by_type(:worker_agent)

  ## Implementation Strategy

  - For testing: Uses local ETS-based mock registry
  - For production: Uses Horde.Registry for distributed operation

  The implementation is selected at compile time based on the Mix environment
  and runtime configuration.
  """

  alias Arbor.Types

  @type agent_metadata :: %{
          required(:type) => :coordinator_agent | :worker_agent | :llm_agent,
          optional(:session_id) => Types.session_id(),
          optional(:capabilities) => [atom()],
          optional(:node) => node(),
          optional(atom()) => any()
        }

  # High-level agent-focused API

  @doc """
  Register an agent in the cluster registry.

  The agent will be discoverable cluster-wide by its ID.
  Registration is automatically removed when the agent process dies.

  ## Parameters

  - `agent_id` - Unique identifier for the agent
  - `agent_pid` - Process ID of the agent
  - `metadata` - Agent metadata including type and capabilities

  ## Returns

  - `:ok` - Agent registered successfully
  - `{:error, :agent_already_registered}` - Agent ID already in use
  - `{:error, reason}` - Registration failed
  """
  @spec register_agent(Types.agent_id(), pid(), agent_metadata()) ::
          :ok | {:error, :agent_already_registered | term()}
  def register_agent(agent_id, agent_pid, metadata) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    case registry_impl.register_name({:agent, agent_id}, agent_pid, metadata, state) do
      :ok -> :ok
      {:error, :name_taken} -> {:error, :agent_already_registered}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Look up an agent and return both PID and metadata.

  ## Returns

  - `{:ok, {agent_pid, metadata}}` - Agent found with metadata
  - `{:error, :agent_not_found}` - Agent not registered
  """
  @spec lookup_agent_with_metadata(Types.agent_id()) ::
          {:ok, {pid(), agent_metadata()}} | {:error, :agent_not_found}
  def lookup_agent_with_metadata(agent_id) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    case registry_impl.lookup_name({:agent, agent_id}, state) do
      {:ok, {pid, metadata}} -> {:ok, {pid, metadata}}
      {:error, :not_registered} -> {:error, :agent_not_found}
    end
  end

  @doc """
  Unregister an agent from the cluster.

  Explicitly removes an agent registration. This is optional as registrations
  are automatically removed when agent processes die.

  ## Returns

  - `:ok` - Agent unregistered
  - `{:error, :agent_not_found}` - Agent was not registered
  """
  @spec unregister_agent(Types.agent_id()) :: :ok | {:error, :agent_not_found}
  def unregister_agent(agent_id) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    case registry_impl.unregister_name({:agent, agent_id}, state) do
      :ok -> :ok
      {:error, :not_registered} -> {:error, :agent_not_found}
    end
  end

  @doc """
  Update metadata for a registered agent.

  Allows updating agent metadata without re-registering.
  Useful for status updates or capability changes.

  ## Returns

  - `:ok` - Metadata updated
  - `{:error, :agent_not_found}` - Agent not registered
  """
  @spec update_agent_metadata(Types.agent_id(), agent_metadata()) ::
          :ok | {:error, :agent_not_found}
  def update_agent_metadata(agent_id, metadata) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    case registry_impl.update_metadata({:agent, agent_id}, metadata, state) do
      :ok -> :ok
      {:error, :not_registered} -> {:error, :agent_not_found}
    end
  end

  @doc """
  List all agents of a specific type.

  Returns all agents in the cluster that match the given type.

  ## Parameters

  - `agent_type` - Type of agents to find (:coordinator_agent, :worker_agent, etc.)

  ## Returns

  - `{:ok, [{agent_id, agent_pid, metadata}]}` - List of matching agents
  """
  @spec list_agents_by_type(atom()) :: {:ok, [{Types.agent_id(), pid(), agent_metadata()}]}
  def list_agents_by_type(agent_type) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    # Get all agent registrations
    {:ok, all_matches} = registry_impl.match({:agent, :_}, state)

    # Filter by type
    filtered =
      all_matches
      |> Enum.filter(fn {_name, _pid, metadata} ->
        Map.get(metadata, :type) == agent_type
      end)
      |> Enum.map(fn {{:agent, agent_id}, pid, metadata} ->
        {agent_id, pid, metadata}
      end)

    {:ok, filtered}
  end

  @doc """
  Get count of registered agents.

  ## Returns

  - `{:ok, count}` - Number of registered agents cluster-wide
  """
  @spec agent_count() :: {:ok, non_neg_integer()}
  def agent_count() do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    # Count only agent registrations (not other types)
    {:ok, all_matches} = registry_impl.match({:agent, :_}, state)
    {:ok, length(all_matches)}
  end

  @doc """
  Register multiple agents under a group.

  Useful for worker pools or coordinated agent groups.

  ## Parameters

  - `group_name` - Name of the agent group
  - `agent_pid` - Agent to add to the group
  - `metadata` - Agent-specific metadata

  ## Returns

  - `:ok` - Agent added to group
  - `{:error, reason}` - Registration failed
  """
  @spec register_agent_group(atom(), pid(), agent_metadata()) :: :ok | {:error, term()}
  def register_agent_group(group_name, agent_pid, metadata) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    registry_impl.register_group({:agent_group, group_name}, agent_pid, metadata, state)
  end

  @doc """
  Look up all agents in a group.

  ## Returns

  - `{:ok, [{pid, metadata}]}` - List of agents in the group
  - `{:error, :group_not_found}` - Group doesn't exist or is empty
  """
  @spec lookup_agent_group(atom()) ::
          {:ok, [{pid(), agent_metadata()}]} | {:error, :group_not_found}
  def lookup_agent_group(group_name) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    registry_impl.lookup_group({:agent_group, group_name}, state)
  end

  @doc """
  Get registry health information.

  Returns metrics about the distributed registry state.

  ## Returns

  Map containing:
  - `:node_count` - Number of nodes in the cluster
  - `:agent_count` - Total number of registered agents
  - `:nodes` - List of connected nodes
  - `:sync_status` - Registry synchronization status
  """
  @spec health_check() :: {:ok, map()}
  def health_check() do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    case registry_impl.health_check(state) do
      {:ok, health} ->
        # Add agent-specific metrics
        {:ok, agent_count} = agent_count()
        enhanced_health = Map.put(health, :agent_count, agent_count)
        {:ok, enhanced_health}

      error ->
        error
    end
  end

  # Low-level registry access (for advanced usage)

  @doc """
  Register a non-agent process in the registry.

  For registering services, temporary processes, or other non-agent components.

  ## Parameters

  - `name` - Unique name for the process
  - `pid` - Process to register
  - `metadata` - Process metadata

  ## Returns

  - `:ok` - Process registered
  - `{:error, :name_taken}` - Name already in use
  """
  @spec register_name(any(), pid(), map()) :: :ok | {:error, :name_taken | term()}
  def register_name(name, pid, metadata) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    registry_impl.register_name(name, pid, metadata, state)
  end

  @doc """
  Look up any registered name.

  Lower-level interface for looking up non-agent registrations.
  """
  @spec lookup_name(any()) :: {:ok, {pid(), map()}} | {:error, :not_registered}
  def lookup_name(name) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    registry_impl.lookup_name(name, state)
  end

  @doc """
  List all registered agents.

  Returns a list of all agents currently registered in the distributed registry.
  """
  @spec list_all_agents() ::
          {:ok, [{Types.agent_id(), pid(), agent_metadata()}]} | {:error, term()}
  def list_all_agents() do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    # Get all agent registrations
    case registry_impl.match({:agent, :_}, state) do
      {:ok, all_matches} ->
        agents =
          Enum.map(all_matches, fn {{:agent, agent_id}, pid, metadata} ->
            {agent_id, pid, metadata}
          end)

        {:ok, agents}

      error ->
        error
    end
  end

  @doc """
  Look up an agent by ID and return PID and metadata separately.

  ## Returns

  - `{:ok, pid, metadata}` - Agent found
  - `{:error, :not_found}` - Agent not registered
  """
  @spec lookup_agent(Types.agent_id()) :: {:ok, pid(), agent_metadata()} | {:error, :not_found}
  def lookup_agent(agent_id) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    case registry_impl.lookup_name({:agent, agent_id}, state) do
      {:ok, {pid, metadata}} -> {:ok, pid, metadata}
      {:error, :not_registered} -> {:error, :not_found}
    end
  end

  @doc """
  Register an agent in a group.

  ## Parameters

  - `group_name` - Name of the group
  - `agent_id` - Agent ID to add to the group

  ## Returns

  - `:ok` - Agent added to group
  - `{:error, reason}` - Failed to add to group
  """
  @spec register_group(String.t() | atom(), Types.agent_id()) :: :ok | {:error, term()}
  def register_group(group_name, agent_id) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    registry_impl.register_group(group_name, agent_id, state)
  end

  @doc """
  List all members of a group.

  ## Returns

  - `{:ok, [agent_id]}` - List of agent IDs in the group
  - `{:error, reason}` - Failed to get group members
  """
  @spec list_group_members(String.t() | atom()) :: {:ok, [Types.agent_id()]} | {:error, term()}
  def list_group_members(group_name) do
    registry_impl = get_registry_impl()

    registry_impl.list_group_members(group_name)
  end

  @doc """
  List agents matching a pattern.

  ## Parameters

  - `pattern` - Pattern to match agent IDs against (supports wildcards)

  ## Returns

  - `{:ok, [{agent_id, pid, metadata}]}` - List of matching agents
  """
  @spec list_by_pattern(String.t()) :: {:ok, [{Types.agent_id(), pid(), agent_metadata()}]}
  def list_by_pattern(pattern) do
    registry_impl = get_registry_impl()
    state = get_registry_state()

    registry_impl.list_by_pattern(pattern, state)
  end

  # Implementation selection

  defp get_registry_impl() do
    # Use configuration to select implementation
    # MOCK: For testing, use local registry
    # For production, use Horde registry
    case Application.get_env(:arbor_core, :registry_impl, :auto) do
      :mock ->
        Arbor.Test.Mocks.LocalRegistry

      :horde ->
        Arbor.Core.HordeRegistry

      :auto ->
        if Application.get_env(:arbor_core, :env) == :test do
          Arbor.Test.Mocks.LocalRegistry
        else
          Arbor.Core.HordeRegistry
        end
    end
  end

  defp get_registry_state() do
    # For mock implementation, create a fresh state
    # For Horde, this would be the actual registry GenServer state
    impl = get_registry_impl()

    case impl do
      Arbor.Test.Mocks.LocalRegistry ->
        # Create a mock state for each call (stateless for unit tests)
        {:ok, state} = impl.start_registry([])
        state

      _ ->
        # For real implementation, this would reference the GenServer
        nil
    end
  end
end
