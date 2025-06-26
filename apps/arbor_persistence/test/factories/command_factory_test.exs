defmodule Arbor.Persistence.CommandFactoryTest do
  @moduledoc """
  Tests for the CommandFactory module.

  Verifies that factory functions generate valid command
  structures with appropriate defaults and customization.
  """

  use Arbor.Persistence.FastCase

  import Arbor.Persistence.CommandFactory

  alias Arbor.Contracts.Client.Command

  describe "spawn_agent_command/1" do
    test "creates valid spawn agent command with defaults" do
      command = spawn_agent_command()

      # Basic command structure
      assert is_map(command)
      assert command.type == :spawn_agent
      assert is_map(command.params)

      # Check parameters
      assert command.params.type == :llm
      assert is_map(command.params.metadata)
      assert command.params.metadata.capabilities == [:text_processing, :reasoning]
      assert command.params.metadata.priority == :normal
      assert command.params.metadata.timeout == 30_000
      assert command.params.metadata.command_source == :test_factory

      # Validate against contract
      assert :ok = validate_command(command)
    end

    test "creates code analyzer command with custom options" do
      command =
        spawn_agent_command(
          agent_type: :code_analyzer,
          agent_id: "analyzer_123",
          working_dir: "/workspace",
          analysis_depth: :comprehensive,
          metrics: [:complexity, :maintainability, :test_coverage]
        )

      assert command.params.type == :code_analyzer
      assert command.params.id == "analyzer_123"
      assert command.params.working_dir == "/workspace"

      # Check agent-specific configuration in metadata
      config = command.params.metadata.configuration
      assert config.analysis_depth == :comprehensive
      assert config.metrics == [:complexity, :maintainability, :test_coverage]
      assert config.file_patterns == ["**/*.ex"]

      # Validate against contract
      assert :ok = validate_command(command)
    end

    test "creates tool executor command with sandbox configuration" do
      command =
        spawn_agent_command(
          agent_type: :tool_executor,
          agent_id: "executor_456",
          allowed_tools: ["git", "mix", "grep", "find"],
          sandbox: true,
          working_directory: "/workspace"
        )

      assert command.params.type == :tool_executor
      assert command.params.id == "executor_456"

      config = command.params.metadata.configuration
      assert config.allowed_tools == ["git", "mix", "grep", "find"]
      assert config.sandbox == true
      assert config.working_directory == "/workspace"

      # Validate against contract
      assert :ok = validate_command(command)
    end
  end

  describe "execute_agent_command/1" do
    test "creates execute agent command" do
      command =
        execute_agent_command(
          agent_id: "agent_123",
          command: "analyze_code",
          args: ["lib/app.ex", "--metrics", "complexity"]
        )

      assert command.type == :execute_agent_command
      assert command.params.agent_id == "agent_123"
      assert command.params.command == "analyze_code"
      assert command.params.args == ["lib/app.ex", "--metrics", "complexity"]

      # Validate against contract
      assert :ok = validate_command(command)
    end
  end

  describe "query_agents_command/1" do
    test "creates query agents command without filter" do
      command = query_agents_command()

      assert command.type == :query_agents
      assert command.params == %{}

      # Validate against contract
      assert :ok = validate_command(command)
    end

    test "creates query agents command with filter" do
      command = query_agents_command(filter: "type=code_analyzer")

      assert command.type == :query_agents
      assert command.params.filter == "type=code_analyzer"

      # Validate against contract
      assert :ok = validate_command(command)
    end
  end

  describe "get_agent_status_command/1" do
    test "creates get agent status command" do
      command = get_agent_status_command(agent_id: "agent_456")

      assert command.type == :get_agent_status
      assert command.params.agent_id == "agent_456"

      # Validate against contract
      assert :ok = validate_command(command)
    end
  end

  describe "custom_command/2" do
    test "creates custom command with type and params" do
      command =
        custom_command(:analyze_project, %{
          path: "/workspace",
          depth: :comprehensive
        })

      assert command.type == :analyze_project
      assert command.params.path == "/workspace"
      assert command.params.depth == :comprehensive
    end
  end

  describe "workflow_command_sequence/2" do
    test "creates basic agent workflow sequence" do
      commands =
        workflow_command_sequence(:basic_agent_workflow,
          agent_type: :code_analyzer
        )

      assert length(commands) == 4

      # Check sequence structure
      [spawn_cmd, query_cmd, status_cmd, execute_cmd] = commands

      # Agent spawning
      assert spawn_cmd.type == :spawn_agent
      assert spawn_cmd.params.type == :code_analyzer

      # Query agents
      assert query_cmd.type == :query_agents
      assert query_cmd.params.filter == "type=code_analyzer"

      # Status check
      assert status_cmd.type == :get_agent_status
      assert is_binary(status_cmd.params.agent_id)

      # Execute command
      assert execute_cmd.type == :execute_agent_command
      assert execute_cmd.params.command == "process_task"
      assert execute_cmd.params.args == ["--input", "test_data"]

      # All commands should be valid
      for command <- commands do
        assert :ok = validate_command(command)
      end
    end

    test "creates multi agent scenario" do
      commands =
        workflow_command_sequence(:multi_agent_scenario,
          agent_types: [:llm, :code_analyzer, :tool_executor]
        )

      # 3 spawn + 1 query
      assert length(commands) == 4

      # Check agent spawning commands
      spawn_cmds = Enum.take(commands, 3)
      query_cmd = Enum.at(commands, 3)

      # Verify spawn commands
      agent_types = Enum.map(spawn_cmds, & &1.params.type)
      assert agent_types == [:llm, :code_analyzer, :tool_executor]

      # Verify query command
      assert query_cmd.type == :query_agents
      assert query_cmd.params == %{}

      # All commands should be valid
      for command <- commands do
        assert :ok = validate_command(command)
      end
    end
  end

  describe "validate_command/1" do
    test "validates commands against the contract" do
      # Valid commands should pass
      valid_command = spawn_agent_command(agent_type: :llm)
      assert :ok = validate_command(valid_command)

      # Invalid command structure should fail
      invalid_command = %{invalid: :structure}
      assert {:error, :invalid_command_structure} = validate_command(invalid_command)

      # Missing required params should fail
      missing_params = %{type: :spawn_agent, params: %{}}
      assert {:error, {:missing_param, :type}} = validate_command(missing_params)
    end
  end

  describe "integration with existing test utilities" do
    test "commands work with event stream testing", %{store: store} do
      # Create a command and convert to events
      command = spawn_agent_command(agent_type: :code_analyzer)

      # Simulate command processing event
      command_event =
        build_test_event(:command_received,
          aggregate_id: "gateway",
          stream_id: "gateway_commands",
          data: %{
            command_type: command.type,
            command_params: command.params
          }
        )

      # Store and verify
      {:ok, _} = Store.append_events("gateway_commands", [command_event], -1, store)
      {:ok, [stored_event]} = Store.read_events("gateway_commands", 0, :latest, store)

      assert stored_event.type == :command_received
      assert stored_event.data.command_type == :spawn_agent
      assert stored_event.data.command_params.type == :code_analyzer
    end

    test "workflow sequences integrate with event sourcing", %{store: store} do
      commands = workflow_command_sequence(:basic_agent_workflow, agent_type: :llm)

      # Convert commands to events
      events =
        commands
        |> Enum.with_index()
        |> Enum.map(fn {command, index} ->
          build_test_event(:command_received,
            aggregate_id: "gateway",
            stream_id: "workflow_commands",
            data: %{
              step: index + 1,
              command_type: command.type,
              command_params: command.params
            }
          )
        end)

      # Store events
      {:ok, _} = Store.append_events("workflow_commands", events, -1, store)

      # Verify workflow sequence
      {:ok, stored_events} = Store.read_events("workflow_commands", 0, :latest, store)

      assert length(stored_events) == 4

      # Check workflow progression
      types = Enum.map(stored_events, & &1.data.command_type)
      assert types == [:spawn_agent, :query_agents, :get_agent_status, :execute_agent_command]
    end
  end
end
