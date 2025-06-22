defmodule Arbor.Contracts.Agents.Coordinator do
  @moduledoc """
  Contract for agent coordination and task delegation.

  The coordinator manages inter-agent communication, task distribution,
  and collaborative workflows. It provides patterns for agents to work
  together effectively while maintaining loose coupling.

  ## Coordination Patterns

  1. **Task Delegation**: Assign tasks to capable agents
  2. **Capability Discovery**: Find agents with specific abilities
  3. **Result Aggregation**: Combine outputs from multiple agents
  4. **Workflow Orchestration**: Multi-step processes across agents

  ## Communication Model

  - **Asynchronous**: Non-blocking message passing
  - **Request-Reply**: Tracked conversations with timeouts
  - **Broadcast**: One-to-many communication
  - **Pub-Sub**: Event-based coordination

  ## Example Implementation

      defmodule MyCoordinator do
        @behaviour Arbor.Contracts.Agents.Coordinator

        @impl true
        def delegate_task(task, requirements, opts, state) do
          with {:ok, agent} <- find_capable_agent(requirements, state),
               {:ok, ref} <- send_task_request(agent, task, opts) do
            {:ok, ref, agent}
          end
        end
      end

  @version "1.0.0"
  """

  alias Arbor.Contracts.Core.Message
  alias Arbor.Types

  @type task_ref :: reference()
  @type task :: map()
  @type requirements :: map()
  @type state :: any()

  @type coordination_error ::
          :no_capable_agents
          | :task_timeout
          | :agent_unavailable
          | :capability_mismatch
          | :delegation_limit_exceeded
          | :invalid_task_format
          | {:error, term()}

  @doc """
  Delegate a task to an agent with required capabilities.

  Finds an appropriate agent and assigns the task, returning a
  reference for tracking the task execution.

  ## Parameters

  - `task` - Task specification
  - `requirements` - Required capabilities/constraints
  - `opts` - Delegation options
  - `state` - Coordinator state

  ## Task Specification

  ```elixir
  %{
    type: :code_analysis,
    payload: %{file: "lib/app.ex", metrics: [:complexity, :coverage]},
    priority: :high,
    timeout: 30_000
  }
  ```

  ## Requirements

  ```elixir
  %{
    capabilities: [:code_analysis, :elixir],
    min_memory: 512_000_000,  # 512MB
    preferred_node: :node1
  }
  ```

  ## Options

  - `:timeout` - Task execution timeout
  - `:retry_count` - Number of retries on failure
  - `:fallback_strategy` - What to do if no agent available

  ## Returns

  - `{:ok, ref, agent_id}` - Task delegated successfully
  - `{:error, :no_capable_agents}` - No agents match requirements
  - `{:error, reason}` - Delegation failed
  """
  @callback delegate_task(
              task(),
              requirements(),
              opts :: keyword(),
              state()
            ) :: {:ok, task_ref(), Types.agent_id()} | {:error, coordination_error()}

  @doc """
  Find agents with specific capabilities.

  Discovers agents that match the given capability requirements,
  useful for capability-based routing and load balancing.

  ## Parameters

  - `requirements` - Capability requirements
  - `state` - Coordinator state

  ## Returns

  - `{:ok, [agent_info]}` - List of capable agents
  - `{:ok, []}` - No agents match requirements

  ## Agent Info

  ```elixir
  %{
    agent_id: "agent_123",
    capabilities: [:code_analysis, :testing],
    current_load: 0.7,  # 0.0 to 1.0
    node: :node1,
    metadata: %{}
  }
  ```
  """
  @callback find_capable_agents(
              requirements(),
              state()
            ) :: {:ok, [map()]} | {:error, coordination_error()}

  @doc """
  Wait for task completion and get result.

  Blocks until the task completes or times out. Use for synchronous
  coordination patterns.

  ## Parameters

  - `task_ref` - Reference from delegate_task/4
  - `timeout` - Maximum wait time
  - `state` - Coordinator state

  ## Returns

  - `{:ok, result}` - Task completed successfully
  - `{:error, :task_timeout}` - Task didn't complete in time
  - `{:error, reason}` - Task failed
  """
  @callback await_task(
              task_ref(),
              timeout(),
              state()
            ) :: {:ok, any()} | {:error, coordination_error()}

  @doc """
  Broadcast a message to multiple agents.

  Sends a message to all agents matching the criteria. Useful for
  notifications, cache invalidation, or coordinated actions.

  ## Parameters

  - `message` - Message to broadcast
  - `recipients` - Recipient specification
  - `opts` - Broadcast options
  - `state` - Coordinator state

  ## Recipient Specification

  ```elixir
  # To specific agents
  {:agents, ["agent_1", "agent_2"]}

  # To agents with capabilities
  {:capabilities, [:code_analysis]}

  # To all agents in session
  {:session, "session_123"}

  # To all agents
  :all
  ```

  ## Options

  - `:delivery` - :best_effort or :guaranteed
  - `:timeout` - Delivery timeout

  ## Returns

  - `{:ok, sent_count}` - Number of agents message sent to
  - `{:error, reason}` - Broadcast failed
  """
  @callback broadcast(
              message :: Message.t(),
              recipients :: tuple() | atom(),
              opts :: keyword(),
              state()
            ) :: {:ok, non_neg_integer()} | {:error, coordination_error()}

  @doc """
  Create a multi-agent workflow.

  Defines a workflow that coordinates multiple agents to complete
  a complex task through a series of steps.

  ## Parameters

  - `workflow` - Workflow definition
  - `context` - Initial workflow context
  - `state` - Coordinator state

  ## Workflow Definition

  ```elixir
  %{
    name: "code_review_workflow",
    steps: [
      %{
        id: :analyze,
        agent_type: :code_analyzer,
        task: %{type: :analyze, payload: %{file: "app.ex"}},
        timeout: 30_000
      },
      %{
        id: :review,
        agent_type: :reviewer,
        task: %{type: :review, payload: %{analysis: "{analyze.result}"}},
        depends_on: [:analyze]
      }
    ],
    on_error: :rollback
  }
  ```

  ## Returns

  - `{:ok, workflow_id}` - Workflow started
  - `{:error, :invalid_workflow}` - Workflow definition invalid
  """
  @callback create_workflow(
              workflow :: map(),
              context :: map(),
              state()
            ) :: {:ok, String.t()} | {:error, coordination_error()}

  @doc """
  Cancel a running task.

  Attempts to cancel a delegated task. The agent may or may not
  be able to cancel depending on the task state.

  ## Parameters

  - `task_ref` - Task to cancel
  - `reason` - Cancellation reason
  - `state` - Coordinator state

  ## Returns

  - `:ok` - Cancellation requested
  - `{:error, :task_not_found}` - Unknown task reference
  """
  @callback cancel_task(
              task_ref(),
              reason :: atom(),
              state()
            ) :: :ok | {:error, coordination_error()}

  @doc """
  Request capability from another agent.

  Initiates a capability negotiation where one agent requests
  a capability from another agent that can grant it.

  ## Parameters

  - `requesting_agent` - Agent making the request
  - `granting_agent` - Agent that may grant capability
  - `capability_spec` - What capability is needed
  - `justification` - Why the capability is needed
  - `state` - Coordinator state

  ## Capability Spec

  ```elixir
  %{
    resource_uri: "arbor://fs/read/secure_data",
    operations: [:read],
    duration: 3_600_000,  # 1 hour
    constraints: %{max_reads: 100}
  }
  ```

  ## Returns

  - `{:ok, capability}` - Capability granted
  - `{:error, :capability_denied}` - Request denied
  - `{:error, reason}` - Request failed
  """
  @callback request_capability(
              requesting_agent :: Types.agent_id(),
              granting_agent :: Types.agent_id(),
              capability_spec :: map(),
              justification :: String.t(),
              state()
            ) :: {:ok, Arbor.Contracts.Core.Capability.t()} | {:error, coordination_error()}

  @doc """
  Get coordination metrics.

  Returns metrics about task delegation, agent utilization,
  and coordination efficiency.

  ## Returns

  Metrics map containing:
  - `:active_tasks` - Currently executing tasks
  - `:queued_tasks` - Tasks waiting for agents
  - `:completed_tasks` - Tasks completed (last hour)
  - `:failed_tasks` - Tasks failed (last hour)
  - `:agent_utilization` - Map of agent_id to utilization %
  - `:average_task_time` - Average task completion time
  - `:delegation_success_rate` - % of successful delegations
  """
  @callback get_metrics(state()) :: {:ok, map()} | {:error, coordination_error()}

  @doc """
  Subscribe to coordination events.

  Allows monitoring of coordination activities for debugging
  and system observation.

  ## Parameters

  - `event_types` - List of events to subscribe to
  - `subscriber` - Process to receive events
  - `state` - Coordinator state

  ## Event Types

  - `:task_delegated` - Task assigned to agent
  - `:task_completed` - Task finished successfully
  - `:task_failed` - Task failed
  - `:agent_unavailable` - Agent can't accept tasks
  - `:capability_granted` - Inter-agent capability grant

  ## Returns

  - `{:ok, subscription_ref}` - Subscribed successfully
  """
  @callback subscribe_events(
              event_types :: [atom()],
              subscriber :: pid(),
              state()
            ) :: {:ok, reference()} | {:error, term()}

  @doc """
  Initialize the coordinator.

  Sets up coordination infrastructure and state.

  ## Options

  - `:max_delegations` - Maximum concurrent task delegations
  - `:default_timeout` - Default task timeout
  - `:retry_strategy` - How to handle task failures

  ## Returns

  - `{:ok, state}` - Coordinator initialized
  - `{:error, reason}` - Initialization failed
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Clean up resources when shutting down.

  Should cancel running tasks and cleanup resources.
  """
  @callback terminate(reason :: term(), state()) :: :ok
end
