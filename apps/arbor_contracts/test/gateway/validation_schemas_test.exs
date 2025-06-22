defmodule Arbor.Contracts.Gateway.ValidationSchemasTest do
  use ExUnit.Case

  alias Arbor.Contracts.Gateway.ValidationSchemas
  alias Arbor.Contracts.Validation
  alias Norm
  import Norm

  # Helper to enable validation for specific tests
  defp enable_validation(_context) do
    Application.put_env(:arbor_contracts, :enable_validation, true)

    # Use on_exit to register the teardown
    on_exit(fn ->
      Application.put_env(:arbor_contracts, :enable_validation, false)
    end)

    :ok
  end

  describe "spawn_agent_command/0" do
    setup :enable_validation

    test "validates valid spawn_agent command" do
      valid_command = %{
        type: :spawn_agent,
        params: %{
          type: :code_analyzer,
          id: "agent-123",
          working_dir: "/tmp/test",
          metadata: %{project: "test"}
        }
      }

      schema = ValidationSchemas.spawn_agent_command()
      assert {:ok, _} = Validation.validate(valid_command, schema)
    end

    test "validates minimal spawn_agent command with only required fields" do
      minimal_command = %{
        type: :spawn_agent,
        params: %{
          type: :code_analyzer
        }
      }

      schema = ValidationSchemas.spawn_agent_command()
      assert {:ok, _} = Validation.validate(minimal_command, schema)
    end

    test "rejects invalid agent type" do
      invalid_command = %{
        type: :spawn_agent,
        params: %{
          type: :invalid_agent_type
        }
      }

      schema = ValidationSchemas.spawn_agent_command()
      assert {:error, _reason} = Validation.validate(invalid_command, schema)
    end

    test "rejects missing required fields" do
      invalid_command = %{
        type: :spawn_agent,
        params: %{}
      }

      schema = ValidationSchemas.spawn_agent_command()
      assert {:error, reason} = Validation.validate(invalid_command, schema)
      assert reason =~ "required field missing"
    end


    test "rejects invalid command type" do
      invalid_command = %{
        type: :invalid_command,
        params: %{
          type: :code_analyzer
        }
      }

      schema = ValidationSchemas.spawn_agent_command()
      assert {:error, _reason} = Validation.validate(invalid_command, schema)
    end
  end

  describe "command_context/0" do
    setup :enable_validation

    test "validates valid context" do
      valid_context = %{
        session_id: "session-123",
        user_id: "user-456",
        client_id: "client-789",
        capabilities: [:spawn_agent, :query_agents],
        trace_id: "trace-abc"
      }

      schema = ValidationSchemas.command_context()
      assert {:ok, _} = Validation.validate(valid_context, schema)
    end

    test "validates context without optional trace_id" do
      minimal_context = %{
        session_id: "session-123",
        user_id: "user-456",
        client_id: "client-789",
        capabilities: []
      }

      schema = ValidationSchemas.command_context()
      assert {:ok, _} = Validation.validate(minimal_context, schema)
    end

    test "rejects empty session_id" do
      invalid_context = %{
        session_id: "",
        user_id: "user-456",
        client_id: "client-789",
        capabilities: []
      }

      schema = ValidationSchemas.command_context()
      assert {:error, _reason} = Validation.validate(invalid_context, schema)
    end
  end

  describe "validation when disabled" do
    test "passes through without validation when disabled" do
      # Validation should be disabled by default in test environment
      refute Validation.is_enabled?()

      # This completely invalid data should pass through
      invalid_data = %{completely: "invalid", data: 123}
      schema = ValidationSchemas.spawn_agent_command()

      assert {:ok, ^invalid_data} = Validation.validate(invalid_data, schema)
    end
  end

  describe "schema access helpers" do
    test "get_schema/1 returns correct schemas" do
      assert ValidationSchemas.get_schema(:spawn_agent) ==
               ValidationSchemas.spawn_agent_command()

      assert ValidationSchemas.get_schema(:command_context) ==
               ValidationSchemas.command_context()

      assert {:error, _} = ValidationSchemas.get_schema(:nonexistent)
    end

    test "available_schemas/0 lists all schemas" do
      schemas = ValidationSchemas.available_schemas()
      assert :spawn_agent in schemas
      assert :command_context in schemas
      assert :command_options in schemas
      assert :full_execution in schemas
    end
  end
end
