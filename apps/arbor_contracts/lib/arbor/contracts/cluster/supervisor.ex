defmodule Arbor.Contracts.Cluster.Supervisor do
  @moduledoc """
  Contract for stateless distributed supervision of agents using Horde.

  This behaviour defines a stateless interface for managing agents across the cluster.
  The implementation is built on three core components:

  ## Architecture Components

  - **HordeSupervisor (Module)**: Stateless API for agent lifecycle management
  - **Horde.Registry**: Distributed, persistent store for agent specifications (desired state)
  - **AgentReconciler (Process)**: Self-healing process that ensures running agents match stored specs

  ## Fault Tolerance Approach

  - **Automatic Restart**: Horde's `process_redistribution: :active` restarts failed agents
  - **Spec Persistence**: Agent specifications stored in distributed CRDT registry
  - **Self-Healing**: AgentReconciler periodically corrects desired vs actual state
  - **No Single Points of Failure**: All state is distributed across cluster nodes

  ## Restart Strategies (Per-Agent)

  - `:permanent` - Always restart agent if it fails
  - `:transient` - Restart only if agent exits abnormally
  - `:temporary` - Never restart agent (remove from system when it exits)

  ## Example Implementation

      defmodule MySupervisor do
        @behaviour Arbor.Contracts.Cluster.Supervisor

        @impl true
        def start_agent(agent_spec) do
          # Store spec in registry for persistence
          register_agent_spec(agent_spec.id, agent_spec)

          child_spec = %{
            id: agent_spec.id,
            start: {agent_spec.module, :start_link, [agent_spec.args]},
            restart: agent_spec.restart_strategy,
            type: :worker
          }

          Horde.DynamicSupervisor.start_child(MyHordeSupervisor, child_spec)
        end
      end

  @version "1.0.0"
  """

  alias Arbor.Types

  @type agent_spec :: %{
          required(:id) => Types.agent_id(),
          required(:module) => module(),
          required(:args) => keyword(),
          optional(:restart_strategy) => :permanent | :temporary | :transient,
          optional(:max_restarts) => non_neg_integer(),
          optional(:max_seconds) => non_neg_integer(),
          optional(:metadata) => map()
        }

  @type reason :: atom() | term()

  @type supervisor_error ::
          :max_children_reached
          | :agent_already_started
          | :agent_not_found
          | :invalid_agent_spec
          | :supervisor_not_ready
          | :migration_failed
          | {:error, term()}

  @doc """
  Start a new agent under distributed supervision.

  Starts an agent that will be supervised and can migrate between
  nodes if the current node fails.

  ## Agent Spec

  Required fields:
  - `:id` - Unique agent identifier
  - `:module` - Agent module implementing Arbor.Agent behaviour
  - `:args` - Arguments passed to agent's init/1

  Optional fields:
  - `:restart_strategy` - How to handle failures (:permanent, :temporary, :transient)
  - `:max_restarts` - Maximum restart attempts
  - `:metadata` - Additional agent metadata

  ## Returns

  - `{:ok, pid}` - Agent started successfully
  - `{:error, :agent_already_started}` - Agent with this ID exists
  - `{:error, reason}` - Start failed

  ## Example

      agent_spec = %{
        id: "agent_llm_123",
        module: Arbor.Agents.LLMAgent,
        args: [model: "gpt-4", temperature: 0.7],
        restart_strategy: :permanent,
        metadata: %{session_id: "session_456"}
      }

      {:ok, pid} = Supervisor.start_agent(agent_spec)
  """
  @callback start_agent(agent_spec()) :: {:ok, pid()} | {:error, supervisor_error()}

  @doc """
  Stop an agent gracefully.

  Attempts to stop the agent cleanly, allowing it to save state
  and cleanup resources before termination.

  ## Parameters

  - `agent_id` - ID of agent to stop
  - `timeout` - Maximum time to wait for graceful shutdown
  - `state` - Supervisor state

  ## Returns

  - `:ok` - Agent stopped successfully
  - `{:error, :agent_not_found}` - Agent doesn't exist
  - `{:error, :timeout}` - Graceful shutdown timed out
  """
  @callback stop_agent(
              agent_id :: Types.agent_id(),
              timeout :: timeout()
            ) :: :ok | {:error, supervisor_error()}

  @doc """
  Restart an agent with the same configuration.

  Stops the agent and starts it again with the same spec.
  Useful for clearing agent state or recovering from errors.

  ## Parameters

  - `agent_id` - Agent to restart
  - `state` - Supervisor state

  ## Returns

  - `{:ok, pid}` - Agent restarted with new PID
  - `{:error, :agent_not_found}` - Agent doesn't exist
  """
  @callback restart_agent(agent_id :: Types.agent_id()) ::
              {:ok, pid()} | {:error, supervisor_error()}

  @doc """
  List all agents under supervision.

  Returns information about all agents currently being supervised
  across the entire cluster.

  ## Returns

  List of agent info maps containing:
  - `:id` - Agent identifier
  - `:pid` - Current process ID
  - `:node` - Node where agent is running
  - `:status` - Agent status (:running, :restarting, etc.)
  - `:restart_count` - Number of times restarted
  - `:started_at` - When agent was started
  - `:metadata` - Agent metadata
  """
  @callback list_agents() ::
              {:ok, [map()]} | {:error, supervisor_error()}

  @doc """
  Get detailed information about a specific agent.

  Returns comprehensive information about an agent including
  supervision tree details and restart history.

  ## Returns

  Agent info map containing:
  - All fields from list_agents/1
  - `:spec` - Original agent specification
  - `:restart_history` - Recent restart timestamps and reasons
  - `:memory` - Current memory usage
  - `:message_queue_len` - Current message queue length
  """
  @callback get_agent_info(agent_id :: Types.agent_id()) ::
              {:ok, map()} | {:error, supervisor_error()}

  @doc """
  Restart an agent with state recovery if available.

  **State Recovery:** If the agent implements the `AgentCheckpoint` behavior,
  this function will attempt to preserve the agent's state during restart.
  Otherwise, the agent restarts with fresh state from its original specification.

  The agent will be restarted according to Horde's distribution strategy,
  which determines optimal node placement based on cluster load and availability.

  ## Parameters

  - `agent_id` - Agent to restart with potential state recovery

  ## Restart Process

  1. Agent specification retrieved from registry
  2. If agent implements checkpointing, current state is captured
  3. Agent is gracefully stopped
  4. Agent is restarted with recovered state (if available) or fresh state
  5. Horde places agent according to distribution strategy

  ## State Recovery

  - **State MAY be preserved** if agent implements `AgentCheckpoint` behavior
  - Agents without checkpointing restart with fresh state
  - State recovery is automatic and transparent to the caller

  ## Returns

  - `{:ok, new_pid}` - Agent restarted successfully
  - `{:error, :agent_not_found}` - Agent spec not found in registry
  - `{:error, :restart_failed}` - Restart process failed
  """
  @callback restore_agent(agent_id :: Types.agent_id()) ::
              {:ok, pid()} | {:error, supervisor_error()}

  @doc """
  Update supervision strategy for an agent.

  Changes how the agent is supervised without restarting it.

  ## Parameters

  - `agent_id` - Agent to update
  - `updates` - Map of supervision updates
  - `state` - Supervisor state

  ## Allowed Updates

  - `:restart_strategy` - Change restart behavior
  - `:max_restarts` - Update restart limit
  - `:max_seconds` - Update restart time window

  ## Returns

  - `:ok` - Strategy updated
  - `{:error, :agent_not_found}` - Agent doesn't exist
  """
  @callback update_agent_spec(
              agent_id :: Types.agent_id(),
              updates :: map()
            ) :: :ok | {:error, supervisor_error()}

  @doc """
  Get supervision tree health metrics.

  Returns metrics about the health and performance of the
  supervision tree across the cluster.

  ## Returns

  Health map containing:
  - `:total_agents` - Number of agents supervised
  - `:running_agents` - Agents currently running
  - `:restarting_agents` - Agents being restarted
  - `:failed_agents` - Agents that failed to restart
  - `:nodes` - List of nodes and agent counts
  - `:restart_intensity` - Recent restart frequency
  - `:memory_usage` - Total memory used by agents
  """
  @callback health_metrics() ::
              {:ok, map()} | {:error, supervisor_error()}

  @doc """
  Set a callback for agent lifecycle events.

  Registers a callback function that will be called when
  agents start, stop, crash, or migrate.

  ## Parameters

  - `event_type` - Type of event to monitor
  - `callback` - Function to call on event
  - `state` - Supervisor state

  ## Event Types

  - `:agent_started` - Agent successfully started
  - `:agent_stopped` - Agent stopped normally
  - `:agent_crashed` - Agent crashed
  - `:agent_restarted` - Agent restarted after crash
  - `:agent_migrated` - Agent moved to different node

  ## Callback Function

  The callback receives: `{event_type, agent_id, details}`
  """
  @callback set_event_handler(
              event_type :: atom(),
              callback :: function()
            ) :: :ok | {:error, term()}

  @doc """
  Handle agent state handoff during migration.

  Called to extract agent state before migration and restore
  it after migration to a new node.

  ## For Extraction

  When `operation` is `:handoff`, extract and return agent state.

  ## For Restoration

  When `operation` is `:takeover`, restore the provided state.
  """
  @callback handle_agent_handoff(
              agent_id :: Types.agent_id(),
              operation :: :handoff | :takeover,
              state_data :: any()
            ) :: {:ok, any()} | {:error, term()}
end
