defmodule ArborCli.Commands.Agent do
  @moduledoc """
  Handles `agent` subcommands for the Arbor CLI.
  """

  @doc """
  Executes a given agent subcommand.

  ## Parameters

    * `subcommand`: An atom representing the subcommand to execute (:spawn, :list, :status, :exec).
    * `args`: A list of arguments for the subcommand.
    * `options`: A keyword list of options.

  ## Returns

    * `{:ok, result}` on success.
    * `{:error, reason}` on failure.
  """
  def execute(subcommand, args, options) do
    session_id = Keyword.get(options, :session_id)

    result =
      case subcommand do
        :spawn -> execute_spawn(session_id, args, options)
        :list -> execute_list(session_id, args, options)
        :status -> execute_status(session_id, args, options)
        :exec -> execute_exec(session_id, args, options)
        _ -> {:error, {:unknown_subcommand, subcommand}}
      end

    result
  end

  defp execute_spawn(session_id, _args, _options) do
    {:ok, "spawn called for session #{session_id}"}
  end

  defp execute_list(session_id, _args, _options) do
    {:ok, "list called for session #{session_id}"}
  end

  defp execute_status(session_id, _args, _options) do
    {:ok, "status called for session #{session_id}"}
  end

  defp execute_exec(session_id, _args, _options) do
    {:ok, "exec called for session #{session_id}"}
  end
end
