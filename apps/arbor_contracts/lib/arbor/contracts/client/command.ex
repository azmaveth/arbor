defmodule Arbor.Contracts.Client.Command do
  @moduledoc """
  Defines the contract for client commands sent to the Gateway.

  This module specifies the structure and validation rules for all commands
  that can be executed through the `Arbor.Contracts.Gateway.API`. It provides
  typespecs and helper functions to construct valid command maps.

  This centralization of command definitions ensures that clients (like the
  Arbor CLI) and the gateway have a single source of truth for command
  structures.

  ## Command Structure

  All commands are represented as maps with a `:type` and `:params` key.

  ```elixir
  %{
    type: :command_name,
    params: %{...}
  }
  ```

  The `t()` type defines the overall structure, and specific types are
  provided for the parameters of each command.
  """

  @type command_type :: :spawn_agent | :query_agents | :get_agent_status | :execute_agent_command

  # Parameter Typespecs

  @typedoc "Parameters for the `:spawn_agent` command."
  @type spawn_agent_params :: %{
          required(:type) => atom(),
          optional(:id) => String.t(),
          optional(:working_dir) => Path.t(),
          optional(:metadata) => map()
        }

  @typedoc "Parameters for the `:query_agents` command."
  @type query_agents_params :: %{
          optional(:filter) => String.t()
        }

  @typedoc "Parameters for the `:get_agent_status` command."
  @type get_agent_status_params :: %{
          required(:agent_id) => String.t()
        }

  @typedoc "Parameters for the `:execute_agent_command` command."
  @type execute_agent_command_params :: %{
          required(:agent_id) => String.t(),
          required(:command) => String.t(),
          required(:args) => [String.t()]
        }

  @type params ::
          spawn_agent_params()
          | query_agents_params()
          | get_agent_status_params()
          | execute_agent_command_params()

  @typedoc """
  Represents a command to be sent to the Gateway.
  """
  @type t :: %{
          type: command_type(),
          params: params()
        }

  # Validation

  @doc """
  Validates a command map against the contract.

  This function checks the command's type and the structure of its parameters.

  ## Parameters
  - `command` - The command map to validate.

  ## Returns
  - `:ok` - The command is valid.
  - `{:error, reason}` - The command is invalid.

  ## Example
      iex> Arbor.Contracts.Client.Command.validate(%{type: :get_agent_status, params: %{agent_id: "agent-123"}})
      :ok

      iex> Arbor.Contracts.Client.Command.validate(%{type: :get_agent_status, params: %{}})
      {:error, {:missing_param, :agent_id}}
  """
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{type: type, params: params}) when is_atom(type) and is_map(params) do
    case type do
      :spawn_agent -> validate_spawn_agent(params)
      :query_agents -> validate_query_agents(params)
      :get_agent_status -> validate_get_agent_status(params)
      :execute_agent_command -> validate_execute_agent_command(params)
      _ -> {:error, {:unknown_command_type, type}}
    end
  end

  def validate(_command) do
    {:error, :invalid_command_structure}
  end

  # Private validation helpers

  defp validate_spawn_agent(params) do
    with :ok <- check_required(params, [:type]),
         :ok <- check_type(params, :type, :is_atom),
         :ok <- check_optional_type(params, :id, :is_binary),
         :ok <- check_optional_type(params, :working_dir, :is_binary) do
      check_optional_type(params, :metadata, :is_map)
    end
  end

  defp validate_query_agents(params) do
    check_optional_type(params, :filter, :is_binary)
  end

  defp validate_get_agent_status(params) do
    with :ok <- check_required(params, [:agent_id]) do
      check_type(params, :agent_id, :is_binary)
    end
  end

  defp validate_execute_agent_command(params) do
    with :ok <- check_required(params, [:agent_id, :command, :args]),
         :ok <- check_type(params, :agent_id, :is_binary),
         :ok <- check_type(params, :command, :is_binary) do
      check_type(params, :args, :is_list)
    end
  end

  defp check_required(params, keys) do
    missing = Enum.filter(keys, fn key -> !Map.has_key?(params, key) end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_param, Enum.at(missing, 0)}}
    end
  end

  defp check_type(params, key, type_fun) do
    val = Map.get(params, key)

    if apply(Kernel, type_fun, [val]) do
      :ok
    else
      {:error, {:invalid_type, key, "expected #{type_fun}"}}
    end
  end

  defp check_optional_type(params, key, type_fun) do
    if Map.has_key?(params, key) do
      check_type(params, key, type_fun)
    else
      :ok
    end
  end

  # Examples

  @doc """
  Provides example command structures.

  This is useful for documentation and testing.

  ## Parameters
  - `type` - The `command_type()` to get an example for.

  ## Returns
  - A valid command map for the given type.
  """
  @spec example(command_type()) :: t()
  def example(:spawn_agent) do
    %{
      type: :spawn_agent,
      params: %{
        type: :my_agent,
        id: "agent-dev-1",
        working_dir: "/tmp/arbor",
        metadata: %{owner: "dev"}
      }
    }
  end

  def example(:query_agents) do
    %{
      type: :query_agents,
      params: %{
        filter: "status=running"
      }
    }
  end

  def example(:get_agent_status) do
    %{
      type: :get_agent_status,
      params: %{
        agent_id: "agent-12345"
      }
    }
  end

  def example(:execute_agent_command) do
    %{
      type: :execute_agent_command,
      params: %{
        agent_id: "agent-12345",
        command: "run_task",
        args: ["task_a", "--verbose"]
      }
    }
  end
end
