defmodule ArborCli.Commands.Agent do
  @moduledoc """
  Agent management commands for the Arbor CLI.

  Provides subcommands for managing the lifecycle of agents:
  - spawn - Create new agents
  - list - List active agents
  - status - Get agent status information
  - exec - Execute commands on agents

  All agent commands work through the Gateway API and require an active session.
  """

  alias Arbor.Contracts.Client.Command
  alias ArborCli.GatewayClient
  
  require Logger

  @doc """
  Execute an agent subcommand.

  ## Subcommands

  - `spawn` - Spawn a new agent
  - `list` - List active agents
  - `status` - Get agent status
  - `exec` - Execute agent command

  ## Parameters

  - `subcommand` - The subcommand to execute
  - `args` - Parsed command arguments
  - `options` - Parsed command options

  ## Returns

  - `{:ok, result}` - Command executed successfully
  - `{:error, reason}` - Command failed
  """
  @spec execute(atom(), [any()], map()) :: {:ok, map()} | {:error, any()}
  def execute(subcommand, args, options) do
    Logger.info("Executing agent command",
      subcommand: subcommand,
      args: length(args),
      options: map_size(options)
    )

    # Create session for this command
    case GatewayClient.create_session(metadata: %{command: "agent #{subcommand}"}) do
      {:ok, session_info} ->
        session_id = session_info.session_id

        try do
          # Execute the specific subcommand
          result =
            case subcommand do
              :spawn -> execute_spawn(session_id, args, options)
              :list -> execute_list(session_id, args, options)
              :status -> execute_status(session_id, args, options)
              :exec -> execute_exec(session_id, args, options)
              _ -> {:error, {:unknown_subcommand, subcommand}}
            end

          result
        after
          # Clean up session
          GatewayClient.end_session(session_id)
        end

      {:error, reason} ->
        {:error, {:session_creation_failed, reason}}
    end
  end

  # Subcommand implementations

  @spec execute_spawn(String.t(), [atom()], map()) :: {:ok, map()} | {:error, any()}
  defp execute_spawn(session_id, [agent_type], options) do
    Logger.info("Spawning agent", type: agent_type, options: options)

    # Build spawn command
    command = %{
      type: :spawn_agent,
      params: build_spawn_params(agent_type, options)
    }

    case Command.validate(command) do
      :ok ->
        # Execute command
        case GatewayClient.execute_command(session_id, command) do
          {:ok, execution_id} ->
            # Wait for completion
            case GatewayClient.wait_for_completion(execution_id) do
              {:ok, result} ->
                {:ok,
                 %{
                   action: "spawn",
                   agent_type: agent_type,
                   result: result
                 }}

              {:error, reason} ->
                {:error, {:spawn_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:command_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_command, reason}}
    end
  end

  @spec execute_spawn(String.t(), [any()], map()) :: {:error, tuple()}
  defp execute_spawn(_session_id, args, _options) do
    {:error, {:invalid_args, "spawn requires exactly one argument (agent type)", args}}
  end

  @spec execute_list(String.t(), [any()], map()) :: {:ok, map()} | {:error, any()}
  defp execute_list(session_id, _args, options) do
    Logger.info("Listing agents", options: options)

    # Build list command
    command = %{
      type: :query_agents,
      params: build_list_params(options)
    }

    case Command.validate(command) do
      :ok ->
        # Execute command
        case GatewayClient.execute_command(session_id, command) do
          {:ok, execution_id} ->
            case GatewayClient.wait_for_completion(execution_id) do
              {:ok, result} ->
                {:ok,
                 %{
                   action: "list",
                   result: result
                 }}

              {:error, reason} ->
                {:error, {:list_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:command_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_command, reason}}
    end
  end

  @spec execute_status(String.t(), [String.t()], map()) :: {:ok, map()} | {:error, any()}
  defp execute_status(session_id, [agent_id], _options) do
    Logger.info("Getting agent status", agent_id: agent_id)

    # Build status command
    command = %{
      type: :get_agent_status,
      params: %{agent_id: agent_id}
    }

    case Command.validate(command) do
      :ok ->
        # Execute command
        case GatewayClient.execute_command(session_id, command) do
          {:ok, execution_id} ->
            case GatewayClient.wait_for_completion(execution_id) do
              {:ok, result} ->
                {:ok,
                 %{
                   action: "status",
                   agent_id: agent_id,
                   result: result
                 }}

              {:error, reason} ->
                {:error, {:status_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:command_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_command, reason}}
    end
  end

  @spec execute_status(String.t(), [any()], map()) :: {:error, tuple()}
  defp execute_status(_session_id, args, _options) do
    {:error, {:invalid_args, "status requires exactly one argument (agent ID)", args}}
  end

  @spec execute_exec(String.t(), [String.t(), ...], map()) :: {:ok, map()} | {:error, any()}
  defp execute_exec(session_id, [agent_id, command | command_args], _options) do
    Logger.info("Executing agent command",
      agent_id: agent_id,
      command: command,
      args: command_args
    )

    # Build exec command
    gateway_command = %{
      type: :execute_agent_command,
      params: %{
        agent_id: agent_id,
        command: command,
        args: command_args
      }
    }

    case Command.validate(gateway_command) do
      :ok ->
        # Execute command
        case GatewayClient.execute_command(session_id, gateway_command) do
          {:ok, execution_id} ->
            case GatewayClient.wait_for_completion(execution_id) do
              {:ok, result} ->
                # Check if the result data contains an error
                case result do
                  %{result: %{data: {:error, reason}}} ->
                    {:error, {:exec_failed, {:error, reason}}}
                  _ ->
                    {:ok,
                     %{
                       action: "exec",
                       agent_id: agent_id,
                       command: command,
                       args: command_args,
                       result: result
                     }}
                end

              {:error, reason} ->
                {:error, {:exec_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:command_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid_command, reason}}
    end
  end

  @spec execute_exec(String.t(), [any()], map()) :: {:error, tuple()}
  defp execute_exec(_session_id, args, _options) do
    {:error, {:invalid_args, "exec requires at least two arguments (agent ID and command)", args}}
  end

  # Helper functions

  @spec build_spawn_params(atom(), map()) :: map()
  defp build_spawn_params(agent_type, options) do
    params = %{type: agent_type}

    params =
      if options[:name] do
        Map.put(params, :id, options.name)
      else
        params
      end

    params =
      if options[:working_dir] do
        Map.put(params, :working_dir, options.working_dir)
      else
        params
      end

    params =
      if options[:metadata] do
        Map.put(params, :metadata, options.metadata)
      else
        params
      end

    params
  end

  @spec build_list_params(map()) :: map()
  defp build_list_params(options) do
    params = %{}

    params =
      if options[:filter] do
        Map.put(params, :filter, options.filter)
      else
        params
      end

    params
  end
end
