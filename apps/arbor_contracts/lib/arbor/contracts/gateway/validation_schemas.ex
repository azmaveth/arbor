defmodule Arbor.Contracts.Gateway.ValidationSchemas do
  @moduledoc """
  Norm validation schemas for Gateway commands.
  
  This module defines runtime validation schemas for critical Gateway 
  commands to catch contract violations that static analysis misses.
  """
  
  import Norm
  
  @doc """
  Schema for spawn_agent command parameters.
  
  Validates the structure and types of spawn_agent command data.
  """
  def spawn_agent_command do
    selection(
      schema(%{
        type: spec(is_atom() and fn x -> x == :spawn_agent end),
        params: spawn_agent_params()
      }),
      [:type, :params]
    )
  end
  
  @doc """
  Schema for spawn_agent parameters.
  """
  def spawn_agent_params do
    selection(
      schema(%{
        type: agent_type(),
        id?: spec(is_binary() and fn s -> String.length(s) > 0 end),
        working_dir?: spec(is_binary() and fn s -> String.length(s) > 0 end),
        metadata?: spec(is_map())
      }),
      [:type]
    )
  end
  
  @doc """
  Schema for valid agent types.
  """
  def agent_type do
    spec(is_atom() and fn type ->
      type in [
        :code_analyzer,
        :test_generator, 
        :documentation_writer,
        :refactoring_assistant,
        :security_auditor,
        :performance_analyzer,
        :api_designer,
        :database_optimizer,
        :deployment_manager,
        :monitoring_specialist
      ]
    end)
  end
  
  @doc """
  Schema for Gateway command context.
  
  Validates the execution context passed with commands.
  """
  def command_context do
    selection(
      schema(%{
        session_id: spec(is_binary() and fn s -> String.length(s) > 0 end),
        user_id: spec(is_binary() and fn s -> String.length(s) > 0 end),
        client_id: spec(is_binary() and fn s -> String.length(s) > 0 end),
        capabilities: spec(is_list()),
        trace_id?: spec(is_binary() and fn s -> String.length(s) > 0 end)
      }),
      [:session_id, :user_id, :client_id, :capabilities]
    )
  end
  
  @doc """
  Schema for command options.
  """
  def command_options do
    schema(%{
      timeout?: spec(is_integer() and fn x -> x > 0 and x <= 300_000 end),  # Max 5 minutes
      priority?: spec(is_atom() and fn x -> x in [:low, :normal, :high, :urgent] end)
    })
  end
  
  @doc """
  Complete schema for a Gateway command execution.
  
  This validates the entire command structure including command, context, and options.
  """
  def gateway_command_execution do
    selection(
      schema(%{
        command: spawn_agent_command(),  # Start with spawn_agent, extend later
        context: command_context(),
        options?: command_options()  # Optional map
      }),
      [:command, :context]
    )
  end
  
  @doc """
  Helper function to get available schemas by name.
  
  This allows dynamic schema selection based on command type.
  """
  def get_schema(:spawn_agent), do: spawn_agent_command()
  def get_schema(:command_context), do: command_context()
  def get_schema(:command_options), do: command_options()
  def get_schema(:full_execution), do: gateway_command_execution()
  def get_schema(schema_name), do: {:error, "Unknown schema: #{inspect(schema_name)}"}
  
  @doc """
  Lists all available validation schemas.
  """
  def available_schemas do
    [
      :spawn_agent,
      :command_context, 
      :command_options,
      :full_execution
    ]
  end
end
