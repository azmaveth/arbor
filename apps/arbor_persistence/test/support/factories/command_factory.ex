defmodule Arbor.Persistence.CommandFactory do
  @moduledoc """
  Sophisticated factory for generating valid command structures matching contract schemas.

  This factory creates realistic command instances that follow Arbor's command patterns
  and work seamlessly with the gateway and agent systems. Commands include proper
  security contexts, capability requirements, and realistic parameter combinations.

  ## Features

  - Gateway command structures matching contract schemas
  - Realistic parameter combinations for each command type
  - Security contexts with proper capability sets
  - Command sequences for testing complex workflows
  - Validation-ready commands that pass gateway checks

  ## Usage

      use Arbor.Persistence.FastCase
      import Arbor.Persistence.CommandFactory
      
      test "command processing workflow", %{store: store} do
        # Create realistic spawn agent command
        command = spawn_agent_command(
          agent_type: :code_analyzer,
          capabilities: [:read_filesystem, :write_reports]
        )
        
        # Create command sequence for distributed workflow
        commands = workflow_command_sequence(:code_analysis,
          repository_url: "https://github.com/example/repo",
          target_files: ["lib/**/*.ex"]
        )
        
        # Validate commands work with gateway
        for cmd <- commands do
          assert {:ok, _} = Gateway.execute_command(cmd, security_context())
        end
      end
  """

  import Arbor.Persistence.FactoryHelpers
  import Arbor.Persistence.FastCase, only: [unique_stream_id: 1, build_test_event: 2]

  alias Arbor.Contracts.Client.Command
  alias Arbor.Contracts.Agents.Messages.{TaskRequest, AgentQuery, CapabilityRequest}
  alias Arbor.Types

  @doc """
  Creates a spawn_agent command with realistic parameters.

  Generates commands that match the gateway's spawn_agent command schema
  with proper security contexts and capability requirements.

  ## Parameters
  - `opts` - Configuration options

  ## Options
  - `:agent_type` - Type of agent to spawn (default: :llm)
  - `:capabilities` - Required capabilities list
  - `:session_id` - Session context
  - `:priority` - Command priority (:low, :normal, :high)
  - `:timeout` - Command timeout in ms
  - `:metadata` - Additional metadata

  ## Examples

      # Basic LLM agent
      command = spawn_agent_command()
      
      # Code analyzer with specific capabilities
      command = spawn_agent_command(
        agent_type: :code_analyzer,
        capabilities: [:read_filesystem, :execute_tools],
        priority: :high,
        timeout: 60_000
      )
  """
  def spawn_agent_command(opts \\ []) do
    agent_type = Keyword.get(opts, :agent_type, :llm)
    capabilities = Keyword.get(opts, :capabilities, default_capabilities_for_type(agent_type))
    session_id = Keyword.get(opts, :session_id, unique_stream_id("session"))
    priority = Keyword.get(opts, :priority, :normal)
    timeout = Keyword.get(opts, :timeout, 30_000)
    metadata = Keyword.get(opts, :metadata, %{})

    # Build params dynamically, only including non-nil values
    params = %{type: agent_type}

    # Add optional fields only if they're provided
    params =
      case Keyword.get(opts, :agent_id) do
        nil -> params
        id -> Map.put(params, :id, id)
      end

    params =
      case Keyword.get(opts, :working_dir) do
        nil -> params
        dir -> Map.put(params, :working_dir, dir)
      end

    # Add metadata
    params =
      Map.put(
        params,
        :metadata,
        Map.merge(
          %{
            capabilities: capabilities,
            configuration: agent_configuration_for_type(agent_type, opts),
            session_id: session_id,
            parent_id: Keyword.get(opts, :parent_id),
            priority: priority,
            timeout: timeout,
            created_at: DateTime.utc_now(),
            command_source: :test_factory
          },
          metadata
        )
      )

    %{
      type: :spawn_agent,
      params: params
    }
  end

  @doc """
  Creates an execute agent command for running tasks on agents.

  Generates commands to execute specific tasks on existing agents.

  ## Examples

      # Execute analysis command on agent
      command = execute_agent_command(
        agent_id: "agent_analyzer_123",
        command: "analyze_code",
        args: ["lib/app.ex", "--metrics", "complexity"]
      )
  """
  def execute_agent_command(opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, unique_stream_id("agent"))
    command = Keyword.get(opts, :command, "process_task")
    args = Keyword.get(opts, :args, [])

    %{
      type: :execute_agent_command,
      params: %{
        agent_id: agent_id,
        command: command,
        args: args
      }
    }
  end

  @doc """
  Creates a query agents command for finding agents.

  Generates commands for querying agents in the cluster.

  ## Examples

      # Find all agents
      command = query_agents_command()
      
      # Find agents with filter
      command = query_agents_command(filter: "type=code_analyzer")
  """
  def query_agents_command(opts \\ []) do
    filter = Keyword.get(opts, :filter)

    params =
      if filter do
        %{filter: filter}
      else
        %{}
      end

    %{
      type: :query_agents,
      params: params
    }
  end

  @doc """
  Creates a get agent status command.

  Generates commands for checking the status of specific agents.

  ## Examples

      # Check agent status
      command = get_agent_status_command(agent_id: "agent_123")
  """
  def get_agent_status_command(opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, unique_stream_id("agent"))

    %{
      type: :get_agent_status,
      params: %{
        agent_id: agent_id
      }
    }
  end

  @doc """
  Creates a command with custom type and parameters.

  Useful for testing custom command structures while maintaining
  the basic command contract format.

  ## Examples

      # Custom command
      command = custom_command(:analyze_project, %{
        path: "/workspace",
        depth: :comprehensive
      })
  """
  def custom_command(command_type, params \\ %{}) do
    %{
      type: command_type,
      params: params
    }
  end

  @doc """
  Creates a sequence of commands for testing basic workflows.

  Generates sequences using the available command types from the contract.

  ## Workflow Types
  - `:basic_agent_workflow` - Spawn, query, status, execute sequence
  - `:multi_agent_scenario` - Multiple agents with different types

  ## Examples

      # Basic agent workflow
      commands = workflow_command_sequence(:basic_agent_workflow,
        agent_type: :code_analyzer
      )
  """
  def workflow_command_sequence(workflow_type, opts \\ []) do
    case workflow_type do
      :basic_agent_workflow ->
        create_basic_agent_workflow(opts)

      :multi_agent_scenario ->
        create_multi_agent_scenario(opts)

      _ ->
        raise ArgumentError, "Unknown workflow type: #{workflow_type}"
    end
  end

  @doc """
  Validates a command against the Command contract.

  Useful for testing that generated commands are valid.
  """
  def validate_command(command) do
    Command.validate(command)
  end

  # Private helper functions

  defp default_capabilities_for_type(:llm), do: [:text_processing, :reasoning]
  defp default_capabilities_for_type(:code_analyzer), do: [:read_filesystem, :static_analysis]
  defp default_capabilities_for_type(:tool_executor), do: [:execute_tools, :system_access]
  defp default_capabilities_for_type(:coordinator), do: [:delegate_tasks, :manage_agents]
  defp default_capabilities_for_type(_), do: [:basic_processing]

  defp agent_configuration_for_type(:llm, opts) do
    %{
      model: Keyword.get(opts, :model, "gpt-4"),
      temperature: Keyword.get(opts, :temperature, 0.7),
      max_tokens: Keyword.get(opts, :max_tokens, 2048),
      system_prompt: Keyword.get(opts, :system_prompt, "You are a helpful AI assistant.")
    }
  end

  defp agent_configuration_for_type(:code_analyzer, opts) do
    %{
      analysis_depth: Keyword.get(opts, :analysis_depth, :standard),
      metrics: Keyword.get(opts, :metrics, [:complexity, :maintainability]),
      file_patterns: Keyword.get(opts, :file_patterns, ["**/*.ex"]),
      exclude_patterns: Keyword.get(opts, :exclude_patterns, ["**/test/**"])
    }
  end

  defp agent_configuration_for_type(:tool_executor, opts) do
    %{
      allowed_tools: Keyword.get(opts, :allowed_tools, ["git", "mix", "grep"]),
      timeout: Keyword.get(opts, :timeout, 30_000),
      sandbox: Keyword.get(opts, :sandbox, true),
      working_directory: Keyword.get(opts, :working_directory, "/tmp")
    }
  end

  defp agent_configuration_for_type(_, _opts), do: %{}

  # Workflow implementations

  defp create_basic_agent_workflow(opts) do
    agent_type = Keyword.get(opts, :agent_type, :llm)
    agent_id = unique_stream_id("agent")

    [
      # 1. Spawn agent
      spawn_agent_command(agent_type: agent_type, agent_id: agent_id),

      # 2. Query agents to find the spawned one
      query_agents_command(filter: "type=#{agent_type}"),

      # 3. Check status
      get_agent_status_command(agent_id: agent_id),

      # 4. Execute a command
      execute_agent_command(
        agent_id: agent_id,
        command: "process_task",
        args: ["--input", "test_data"]
      )
    ]
  end

  defp create_multi_agent_scenario(opts) do
    agent_types = Keyword.get(opts, :agent_types, [:llm, :code_analyzer, :tool_executor])

    # Spawn different types of agents
    spawn_commands =
      Enum.map(agent_types, fn type ->
        spawn_agent_command(agent_type: type)
      end)

    # Query all agents
    query_command = query_agents_command()

    spawn_commands ++ [query_command]
  end
end
