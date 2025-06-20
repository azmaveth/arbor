defmodule Arbor.Contracts.Cluster.Supervisor do
  @moduledoc """
  Contract for distributed supervision of agents using Horde.

  This behaviour defines how agents are supervised across the cluster,
  handling node failures, rebalancing, and state handoff. It provides
  the foundation for Arbor's fault-tolerant agent orchestration.

  ## Supervision Guarantees

  - **Automatic Restart**: Failed agents are restarted according to strategy
  - **Node Migration**: Agents migrate when nodes fail
  - **State Preservation**: Agent state is preserved across restarts
  - **Load Balancing**: Agents are distributed across healthy nodes

  ## Supervision Strategies

  - `:one_for_one` - Restart only the failed agent
  - `:rest_for_one` - Restart failed agent and those started after it
  - `:one_for_all` - Restart all agents if one fails

  ## Example Implementation

      defmodule MySupervisor do
        @behaviour Arbor.Contracts.Cluster.Supervisor
        
        @impl true
        def start_agent(agent_spec, state) do
          child_spec = %{
            id: agent_spec.id,
            start: {agent_spec.module, :start_link, [agent_spec.args]},
            restart: agent_spec.restart_strategy,
            type: :worker
          }
          
          Horde.DynamicSupervisor.start_child(state.supervisor, child_spec)
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

  @type state :: any()
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
      
      {:ok, pid} = Supervisor.start_agent(agent_spec, state)
  """
  @callback start_agent(
              agent_spec(),
              state()
            ) :: {:ok, pid()} | {:error, supervisor_error()}

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
              timeout :: timeout(),
              state()
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
  @callback restart_agent(
              agent_id :: Types.agent_id(),
              state()
            ) :: {:ok, pid()} | {:error, supervisor_error()}

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
  @callback list_agents(state()) ::
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
  @callback get_agent_info(
              agent_id :: Types.agent_id(),
              state()
            ) :: {:ok, map()} | {:error, supervisor_error()}

  @doc """
  Move an agent to a specific node.

  Triggers migration of an agent from its current node to a target node.
  The agent's state is preserved during migration.

  ## Parameters

  - `agent_id` - Agent to migrate
  - `target_node` - Node to migrate to
  - `state` - Supervisor state

  ## Migration Process

  1. Agent state is extracted
  2. Agent is stopped on current node
  3. Agent is started on target node
  4. State is restored
  5. Registrations are updated

  ## Returns

  - `{:ok, new_pid}` - Migration successful
  - `{:error, :agent_not_found}` - Agent doesn't exist
  - `{:error, :node_not_available}` - Target node not in cluster
  - `{:error, :migration_failed}` - Migration process failed
  """
  @callback migrate_agent(
              agent_id :: Types.agent_id(),
              target_node :: node(),
              state()
            ) :: {:ok, pid()} | {:error, supervisor_error()}

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
              updates :: map(),
              state()
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
  @callback health_metrics(state()) ::
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
              callback :: function(),
              state()
            ) :: :ok | {:error, term()}

  @doc """
  Start the distributed supervisor infrastructure.

  Sets up the Horde supervisor infrastructure including CRDT components.
  This is distinct from GenServer.init/1 and manages the supervisor component lifecycle.

  ## Options

  - `:name` - Supervisor name
  - `:strategy` - Default supervision strategy
  - `:max_children` - Maximum agents to supervise
  - `:delta_crdt_options` - Horde CRDT options

  ## Returns

  - `{:ok, state}` - Supervisor initialized
  - `{:error, reason}` - Initialization failed
  """
  @callback start_supervisor(opts :: keyword()) :: {:ok, state()} | {:error, term()}

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
              state_data :: any(),
              state()
            ) :: {:ok, any()} | {:error, term()}

  @doc """
  Stop the distributed supervisor and clean up resources.

  This handles supervisor component shutdown and is distinct from GenServer.terminate/2.
  Should gracefully stop all agents and cleanup supervisor resources.
  """
  @callback stop_supervisor(reason :: term(), state()) :: :ok
end
