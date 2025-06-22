defmodule Arbor.Contracts.Agents.Messages do
  @moduledoc """
  Message schemas for agent coordination and task management.

  This module defines the structured messages used for inter-agent
  communication, task delegation, and coordination. All messages
  are wrapped in the standard Message envelope.

  ## Message Categories

  1. **Task Messages**: Task assignment and results
  2. **Coordination Messages**: Agent discovery and negotiation
  3. **Capability Messages**: Permission requests and grants
  4. **Status Messages**: Health checks and status updates

  @version "1.0.0"
  """

  use TypedStruct

  alias Arbor.Contracts.Core.Capability
  alias Arbor.Types

  # Task Request - Sent to delegate work to an agent
  defmodule TaskRequest do
    @moduledoc """
    Request for an agent to perform a task.

    Used by coordinators to assign work to agents with
    appropriate capabilities.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:task_id, String.t())
      field(:task_type, atom())
      field(:payload, map())
      field(:requirements, map(), default: %{})
      field(:timeout, pos_integer(), default: 30_000)
      field(:priority, atom(), default: :normal)
      field(:reply_to, Types.agent_id())
      field(:context, map(), default: %{})
    end

    @doc """
    Create a new task request.

    ## Example

        TaskRequest.new(
          task_type: :code_analysis,
          payload: %{file: "lib/app.ex", metrics: [:complexity]},
          reply_to: "agent_coordinator_123",
          timeout: 60_000
        )
    """
    @spec new(keyword()) :: {:ok, t()} | {:error, term()}
    def new(attrs) do
      task = %__MODULE__{
        task_id: attrs[:task_id] || generate_task_id(),
        task_type: Keyword.fetch!(attrs, :task_type),
        payload: Keyword.fetch!(attrs, :payload),
        requirements: attrs[:requirements] || %{},
        timeout: attrs[:timeout] || 30_000,
        priority: attrs[:priority] || :normal,
        reply_to: Keyword.fetch!(attrs, :reply_to),
        context: attrs[:context] || %{}
      }

      {:ok, task}
    end

    @spec generate_task_id() :: String.t()
    defp generate_task_id do
      "task_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    end
  end

  # Task Response - Results from task execution
  defmodule TaskResponse do
    @moduledoc """
    Response containing task execution results.

    Sent by agents back to coordinators when tasks complete
    or fail.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:task_id, String.t())
      field(:status, atom())
      field(:result, any(), enforce: false)
      field(:error, term(), enforce: false)
      field(:execution_time, non_neg_integer())
      field(:agent_id, Types.agent_id())
      field(:metadata, map(), default: %{})
    end

    @valid_statuses [:success, :failure, :timeout, :cancelled]

    @spec new(keyword()) :: {:ok, t()} | {:error, term()}
    def new(attrs) do
      response = %__MODULE__{
        task_id: Keyword.fetch!(attrs, :task_id),
        status: Keyword.fetch!(attrs, :status),
        result: attrs[:result],
        error: attrs[:error],
        execution_time: Keyword.fetch!(attrs, :execution_time),
        agent_id: Keyword.fetch!(attrs, :agent_id),
        metadata: attrs[:metadata] || %{}
      }

      if response.status in @valid_statuses do
        {:ok, response}
      else
        {:error, {:invalid_status, response.status}}
      end
    end
  end

  # Agent Query - Find agents with specific capabilities
  defmodule AgentQuery do
    @moduledoc """
    Query for discovering agents with specific capabilities.

    Used to find suitable agents for task delegation or
    collaboration.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:query_id, String.t())
      field(:required_capabilities, [atom()], default: [])
      field(:preferred_capabilities, [atom()], default: [])
      field(:constraints, map(), default: %{})
      field(:limit, pos_integer(), enforce: false)
    end

    @spec new(keyword()) :: {:ok, t()} | {:error, term()}
    def new(attrs) do
      query = %__MODULE__{
        query_id: attrs[:query_id] || generate_query_id(),
        required_capabilities: attrs[:required_capabilities] || [],
        preferred_capabilities: attrs[:preferred_capabilities] || [],
        constraints: attrs[:constraints] || %{},
        limit: attrs[:limit]
      }

      {:ok, query}
    end

    @spec generate_query_id() :: String.t()
    defp generate_query_id do
      "query_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    end
  end

  # Agent Info - Response to agent query
  defmodule AgentInfo do
    @moduledoc """
    Information about an agent's capabilities and status.

    Returned in response to agent queries or status requests.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:agent_id, Types.agent_id())
      field(:agent_type, Types.agent_type())
      field(:capabilities, [atom()], default: [])
      field(:status, atom())
      field(:current_load, float(), default: 0.0)
      field(:available, boolean(), default: true)
      field(:node, atom())
      field(:metadata, map(), default: %{})
    end
  end

  # Capability Request - Request permission from another agent
  defmodule CapabilityRequest do
    @moduledoc """
    Request for capability delegation between agents.

    Used when one agent needs permissions that another
    agent can grant.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:request_id, String.t())
      field(:requesting_agent, Types.agent_id())
      field(:resource_uri, Types.resource_uri())
      field(:operations, [Types.operation()], default: [:read])
      field(:duration, pos_integer(), enforce: false)
      field(:justification, String.t())
      field(:constraints, map(), default: %{})
    end

    @spec new(keyword()) :: {:ok, t()} | {:error, term()}
    def new(attrs) do
      request = %__MODULE__{
        request_id: attrs[:request_id] || generate_request_id(),
        requesting_agent: Keyword.fetch!(attrs, :requesting_agent),
        resource_uri: Keyword.fetch!(attrs, :resource_uri),
        operations: attrs[:operations] || [:read],
        duration: attrs[:duration],
        justification: Keyword.fetch!(attrs, :justification),
        constraints: attrs[:constraints] || %{}
      }

      if Types.valid_resource_uri?(request.resource_uri) do
        {:ok, request}
      else
        {:error, {:invalid_resource_uri, request.resource_uri}}
      end
    end

    @spec generate_request_id() :: String.t()
    defp generate_request_id do
      "capreq_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    end
  end

  # Capability Response - Grant or denial of capability request
  defmodule CapabilityResponse do
    @moduledoc """
    Response to a capability request.

    Contains either the granted capability or reason for denial.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:request_id, String.t())
      field(:status, atom())
      field(:capability, Capability.t(), enforce: false)
      field(:reason, atom() | String.t(), enforce: false)
      field(:granting_agent, Types.agent_id())
    end

    @valid_statuses [:granted, :denied, :pending_approval]

    @spec new(keyword()) :: {:ok, t()} | {:error, term()}
    def new(attrs) do
      response = %__MODULE__{
        request_id: Keyword.fetch!(attrs, :request_id),
        status: Keyword.fetch!(attrs, :status),
        capability: attrs[:capability],
        reason: attrs[:reason],
        granting_agent: Keyword.fetch!(attrs, :granting_agent)
      }

      cond do
        response.status not in @valid_statuses ->
          {:error, {:invalid_status, response.status}}

        response.status == :granted and is_nil(response.capability) ->
          {:error, :missing_capability}

        response.status == :denied and is_nil(response.reason) ->
          {:error, :missing_denial_reason}

        true ->
          {:ok, response}
      end
    end
  end

  # Health Check - Request agent health status
  defmodule HealthCheck do
    @moduledoc """
    Health check request for agent status monitoring.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:check_id, String.t())
      field(:reply_to, Types.agent_id())
      field(:include_metrics, boolean(), default: false)
    end
  end

  # Health Response - Agent health status
  defmodule HealthResponse do
    @moduledoc """
    Response to health check with agent status information.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:check_id, String.t())
      field(:agent_id, Types.agent_id())
      field(:status, atom())
      field(:uptime, non_neg_integer())
      field(:metrics, map(), default: %{})
    end
  end

  # Coordination Event - Notify about coordination activities
  defmodule CoordinationEvent do
    @moduledoc """
    Event notification for coordination activities.

    Used to inform interested agents about task delegations,
    completions, and other coordination events.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:event_id, String.t())
      field(:event_type, atom())
      field(:source_agent, Types.agent_id())
      field(:target_agent, Types.agent_id(), enforce: false)
      field(:task_id, String.t(), enforce: false)
      field(:timestamp, DateTime.t())
      field(:details, map(), default: %{})
    end
  end
end
