defmodule Arbor.Core.ClusterSupervisor do
  @moduledoc """
  Distributed agent supervision using Horde for cluster-wide fault tolerance.

  This module provides a consistent interface for agent supervision and lifecycle
  management across the Arbor cluster. It uses Horde for the distributed implementation
  but can fall back to local-only implementation for testing.

  ## Usage

  Agents are supervised cluster-wide with automatic failover:

      # Start an agent under supervision
      agent_spec = %{
        id: "agent-123",
        module: MyAgent,
        args: [config: %{}],
        restart_strategy: :permanent
      }
      ClusterSupervisor.start_agent(agent_spec)
      
      # Agent will automatically restart on failures
      # and migrate to healthy nodes if current node fails
      
      # Get agent status
      {:ok, info} = ClusterSupervisor.get_agent_info("agent-123")
      
      # Manually migrate agent to different node
      ClusterSupervisor.migrate_agent("agent-123", :"other@node")

  ## Implementation Strategy

  - For testing: Uses local process-based mock supervision
  - For production: Uses Horde.DynamicSupervisor for distributed operation

  The implementation is selected at compile time based on the Mix environment
  and runtime configuration.
  """

  alias Arbor.Types
  alias Arbor.Contracts.Cluster.Supervisor, as: SupervisorContract

  @type agent_spec :: SupervisorContract.agent_spec()
  @type supervisor_error :: SupervisorContract.supervisor_error()

  # High-level agent supervision API

  @doc """
  Start an agent under distributed supervision.

  The agent will be supervised cluster-wide and can automatically migrate
  between nodes on failures.

  ## Agent Specification

  Required fields:
  - `:id` - Unique agent identifier
  - `:module` - Agent module implementing appropriate behaviour
  - `:args` - Arguments passed to agent initialization

  Optional fields:
  - `:restart_strategy` - `:permanent`, `:temporary`, or `:transient`
  - `:max_restarts` - Maximum restart attempts (default: 5)
  - `:max_seconds` - Time window for restart limit (default: 30)
  - `:metadata` - Additional agent metadata

  ## Returns

  - `{:ok, pid}` - Agent started successfully
  - `{:error, :agent_already_started}` - Agent ID already exists
  - `{:error, reason}` - Start failed
  """
  @spec start_agent(agent_spec()) :: {:ok, pid()} | {:error, supervisor_error()}
  def start_agent(agent_spec) do
    supervisor_impl = get_supervisor_impl()
    state = get_supervisor_state()

    # Ensure required fields and set defaults
    validated_spec = validate_and_normalize_spec(agent_spec)

    case supervisor_impl.start_agent(validated_spec, state) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stop an agent gracefully.

  Attempts to stop the agent cleanly with the specified timeout.

  ## Parameters

  - `agent_id` - Agent to stop
  - `timeout` - Maximum time to wait for graceful shutdown (default: 5000ms)

  ## Returns

  - `:ok` - Agent stopped successfully
  - `{:error, :agent_not_found}` - Agent doesn't exist
  - `{:error, :timeout}` - Graceful shutdown timed out
  """
  @spec stop_agent(Types.agent_id(), timeout()) :: :ok | {:error, supervisor_error()}
  def stop_agent(agent_id, timeout \\ 5000) do
    supervisor_impl = get_supervisor_impl()
    state = get_supervisor_state()

    supervisor_impl.stop_agent(agent_id, timeout, state)
  end

  @doc """
  Restart an agent with the same configuration.

  Stops the agent and starts it again with the same specification.
  Useful for clearing agent state or recovering from errors.

  ## Returns

  - `{:ok, new_pid}` - Agent restarted successfully
  - `{:error, :agent_not_found}` - Agent doesn't exist
  """
  @spec restart_agent(Types.agent_id()) :: {:ok, pid()} | {:error, supervisor_error()}
  def restart_agent(agent_id) do
    supervisor_impl = get_supervisor_impl()
    state = get_supervisor_state()

    supervisor_impl.restart_agent(agent_id, state)
  end

  @doc """
  Get detailed information about a specific agent.

  Returns comprehensive information including supervision details,
  restart history, and current process metrics.

  ## Returns

  Agent info map containing:
  - `:id` - Agent identifier
  - `:pid` - Current process ID
  - `:node` - Node where agent is running
  - `:status` - Current status (:running, :restarting, etc.)
  - `:restart_count` - Number of times restarted
  - `:started_at` - When agent was started (timestamp)
  - `:metadata` - Agent metadata
  - `:spec` - Original agent specification
  - `:restart_history` - Recent restart events
  - `:memory` - Current memory usage in bytes
  - `:message_queue_len` - Current message queue length
  """
  @spec get_agent_info(Types.agent_id()) :: {:ok, map()} | {:error, supervisor_error()}
  def get_agent_info(agent_id) do
    supervisor_impl = get_supervisor_impl()
    state = get_supervisor_state()

    supervisor_impl.get_agent_info(agent_id, state)
  end

  @doc """
  List all agents under supervision.

  Returns basic information about all agents currently being supervised
  across the entire cluster.

  ## Returns

  List of agent info maps containing basic fields from get_agent_info/1.
  """
  @spec list_agents() :: {:ok, [map()]} | {:error, supervisor_error()}
  def list_agents() do
    supervisor_impl = get_supervisor_impl()
    state = get_supervisor_state()

    supervisor_impl.list_agents(state)
  end

  @doc """
  Move an agent to a specific node.

  Triggers migration of an agent from its current node to the target node.
  Agent state is preserved during migration.

  ## Migration Process

  1. Agent state is extracted via handoff
  2. Agent is stopped on current node
  3. Agent is started on target node
  4. State is restored via takeover
  5. Registry entries are updated

  ## Returns

  - `{:ok, new_pid}` - Migration successful
  - `{:error, :agent_not_found}` - Agent doesn't exist
  - `{:error, :node_not_available}` - Target node not in cluster
  - `{:error, :migration_failed}` - Migration process failed
  """
  @spec migrate_agent(Types.agent_id(), node()) :: {:ok, pid()} | {:error, supervisor_error()}
  def migrate_agent(agent_id, target_node) do
    supervisor_impl = get_supervisor_impl()
    state = get_supervisor_state()

    supervisor_impl.migrate_agent(agent_id, target_node, state)
  end

  @doc """
  Update supervision strategy for an agent.

  Changes how the agent is supervised without restarting it.

  ## Allowed Updates

  - `:restart_strategy` - Change restart behavior
  - `:max_restarts` - Update restart limit
  - `:max_seconds` - Update restart time window
  - `:metadata` - Update agent metadata

  ## Returns

  - `:ok` - Strategy updated successfully
  - `{:error, :agent_not_found}` - Agent doesn't exist
  """
  @spec update_agent_spec(Types.agent_id(), map()) :: :ok | {:error, supervisor_error()}
  def update_agent_spec(agent_id, updates) do
    supervisor_impl = get_supervisor_impl()
    state = get_supervisor_state()

    supervisor_impl.update_agent_spec(agent_id, updates, state)
  end

  @doc """
  Get supervision tree health metrics.

  Returns comprehensive metrics about the health and performance of
  the supervision tree across the cluster.

  ## Returns

  Health map containing:
  - `:total_agents` - Number of agents supervised
  - `:running_agents` - Agents currently running
  - `:restarting_agents` - Agents being restarted
  - `:failed_agents` - Agents that failed to restart
  - `:nodes` - List of nodes and agent distribution
  - `:restart_intensity` - Recent restart frequency
  - `:memory_usage` - Total memory used by agents
  """
  @spec health_metrics() :: {:ok, map()} | {:error, supervisor_error()}
  def health_metrics() do
    supervisor_impl = get_supervisor_impl()
    state = get_supervisor_state()

    supervisor_impl.health_metrics(state)
  end

  @doc """
  Set a callback for agent lifecycle events.

  Registers a callback function that will be called when agents
  start, stop, crash, migrate, or experience other lifecycle events.

  ## Event Types

  - `:agent_started` - Agent successfully started
  - `:agent_stopped` - Agent stopped normally
  - `:agent_crashed` - Agent crashed unexpectedly
  - `:agent_restarted` - Agent restarted after crash
  - `:agent_migrated` - Agent moved to different node

  ## Callback Function

  The callback receives: `{event_type, agent_id, event_details}`

  ## Returns

  - `:ok` - Event handler registered
  - `{:error, reason}` - Registration failed
  """
  @spec set_event_handler(atom(), function()) :: :ok | {:error, term()}
  def set_event_handler(event_type, callback) do
    supervisor_impl = get_supervisor_impl()
    state = get_supervisor_state()

    supervisor_impl.set_event_handler(event_type, callback, state)
  end

  @doc """
  Extract agent state for handoff during migration.

  Low-level function for state management during agent migration.
  Usually called automatically during migrate_agent/2.

  ## Returns

  - `{:ok, agent_state}` - State extracted successfully
  - `{:error, :agent_not_found}` - Agent doesn't exist
  """
  @spec extract_agent_state(Types.agent_id()) :: {:ok, any()} | {:error, term()}
  def extract_agent_state(agent_id) do
    supervisor_impl = get_supervisor_impl()
    state = get_supervisor_state()

    supervisor_impl.handle_agent_handoff(agent_id, :handoff, nil, state)
  end

  @doc """
  Restore agent state after takeover during migration.

  Low-level function for state management during agent migration.
  Usually called automatically during migrate_agent/2.

  ## Returns

  - `{:ok, restored_state}` - State restored successfully
  - `{:error, reason}` - Restoration failed
  """
  @spec restore_agent_state(Types.agent_id(), any()) :: {:ok, any()} | {:error, term()}
  def restore_agent_state(agent_id, agent_state) do
    supervisor_impl = get_supervisor_impl()
    state = get_supervisor_state()

    supervisor_impl.handle_agent_handoff(agent_id, :takeover, agent_state, state)
  end

  # Convenience functions for specific agent types

  @doc """
  Start a coordinator agent with predefined configuration.

  Coordinator agents use `:permanent` restart strategy and are distributed
  to ensure high availability.
  """
  @spec start_coordinator_agent(Types.agent_id(), module(), keyword(), map()) ::
          {:ok, pid()} | {:error, supervisor_error()}
  def start_coordinator_agent(agent_id, module, args, metadata \\ %{}) do
    agent_spec = %{
      id: agent_id,
      module: module,
      args: args,
      restart_strategy: :permanent,
      max_restarts: 5,
      max_seconds: 30,
      metadata: Map.put(metadata, :agent_type, :coordinator)
    }

    start_agent(agent_spec)
  end

  @doc """
  Start a worker agent with predefined configuration.

  Worker agents use `:transient` restart strategy and can be temporary
  based on workload requirements.
  """
  @spec start_worker_agent(Types.agent_id(), module(), keyword(), map()) ::
          {:ok, pid()} | {:error, supervisor_error()}
  def start_worker_agent(agent_id, module, args, metadata \\ %{}) do
    agent_spec = %{
      id: agent_id,
      module: module,
      args: args,
      restart_strategy: :transient,
      max_restarts: 3,
      max_seconds: 60,
      metadata: Map.put(metadata, :agent_type, :worker)
    }

    start_agent(agent_spec)
  end

  # Implementation selection

  defp get_supervisor_impl() do
    # Use configuration to select implementation
    # MOCK: For testing, use local supervisor
    # For production, use Horde supervisor
    case Application.get_env(:arbor_core, :supervisor_impl, :auto) do
      :mock ->
        Arbor.Test.Mocks.LocalSupervisor

      :horde ->
        Arbor.Core.HordeSupervisor

      :auto ->
        if Mix.env() == :test do
          Arbor.Test.Mocks.LocalSupervisor
        else
          Arbor.Core.HordeSupervisor
        end
    end
  end

  defp get_supervisor_state() do
    # For mock implementation, create a fresh state
    # For Horde, this would be the actual supervisor state
    impl = get_supervisor_impl()

    case impl do
      Arbor.Test.Mocks.LocalSupervisor ->
        # Create a mock state for each call (stateless for unit tests)
        {:ok, state} = impl.start_supervisor([])
        state

      _ ->
        # For real implementation, this would reference the GenServer
        nil
    end
  end

  defp validate_and_normalize_spec(agent_spec) do
    # Ensure required fields are present
    required_fields = [:id, :module, :args]

    for field <- required_fields do
      unless Map.has_key?(agent_spec, field) do
        raise ArgumentError, "Agent spec missing required field: #{field}"
      end
    end

    # Set defaults for optional fields
    defaults = %{
      restart_strategy: :permanent,
      max_restarts: 5,
      max_seconds: 30,
      metadata: %{}
    }

    Map.merge(defaults, agent_spec)
  end
end
