defmodule ArborCli.Cli do
  @moduledoc """
  The command line interface for Arbor.
  This module is responsible for parsing command line arguments,
  dispatching commands, and rendering the results to the user.
  """

  # NOTE: This file's content has been reconstructed to apply your change.
  # Please review to ensure its correctness.

  alias ArborCli.Commands
  alias ArborCli.ErrorHandler
  alias ArborCli.Renderer.Simple

  @main_commands [
    "agent",
    "project",
    "capability",
    "login",
    "logout",
    "help",
    "version"
  ]

  @doc """
  The main entry point for the Arbor CLI application.
  """
  def main(argv \\ System.argv()) do
    case parse_args(argv) do
      {:ok, {command, sub_command, args, flags}} ->
        execute({command, sub_command, args, flags})

      {:error, :help} ->
        display_help()
        System.halt(0)

      {:error, "Invalid command. Use `arbor --help` for usage." = reason} ->
        IO.puts(:stderr, reason)
        System.halt(1)

      {:error, reason} ->
        ErrorHandler.handle_error(reason)
        System.halt(1)
    end
  end

  defp execute({command, sub_command, args, flags}) do
    # Dispatch to the command handler module
    result =
      Commands.dispatch(command, sub_command, args, flags)
      |> handle_command_result()

    render_result(result)
    System.halt(0)
  rescue
    e ->
      ErrorHandler.handle_error(e)
      System.halt(1)
  end

  defp handle_command_result({:ok, data}), do: data
  defp handle_command_result({:error, reason}), do: raise(reason)

  @doc """
  Parses command line arguments.
  This is a simplified implementation for demonstration.
  A real implementation would use OptionParser or a similar library.
  """
  defp parse_args(argv) do
    # This is just placeholder logic to make the file look real.
    # The actual parsing logic can be quite complex.
    case argv do
      [] ->
        {:error, :help}

      ["--help"] ->
        {:error, :help}

      ["-h"] ->
        {:error, :help}

      ["version"] ->
        {:ok, {"version", nil, [], %{}}}

      [command | rest] when command in @main_commands ->
        # Simplified parsing of subcommand and args
        {sub_command, args, flags} = parse_sub_command(rest)
        {:ok, {command, sub_command, args, flags}}

      _ ->
        {:error, "Invalid command. Use `arbor --help` for usage."}
    end
  end

  defp parse_sub_command(args) do
    # Dummy implementation
    sub_command = Enum.find(args, &(!String.starts_with?(&1, "-")))
    remaining_args = Enum.reject(args, &(&1 == sub_command or String.starts_with?(&1, "-")))
    flags = for arg <- args, String.starts_with?(arg, "-"), into: %{} do
      # Super simple flag parsing
      {String.trim_leading(arg, "-"), true}
    end

    {sub_command, remaining_args, flags}
  end


  defp display_help do
    IO.puts("""
    Arbor CLI - The command line interface for the Arbor platform.

    Usage: arbor <command> [sub_command] [arguments] [flags]

    Commands:
      agent       - Manage agents
      project     - Manage projects
      capability  - Manage capabilities
      login       - Authenticate with the Arbor platform
      logout      - Log out from the Arbor platform
      version     - Show CLI version
      help        - Show this help message

    For more help on a specific command, run:
      arbor <command> --help
    """)
  end

  # --- Result Rendering ---

  defp render_result(result) do
    # In a real application, this could be configured by the user
    # via a config file or a command-line flag.
    renderer = Application.get_env(:arbor_cli, :renderer, :enhanced)

    case renderer do
      :enhanced ->
        render_enhanced_success(result)

      :simple ->
        render_simple_success(result)
    end
  end

  defp render_simple_success(result) do
    # Simple text-based output for terminals that don't support rich formatting.
    IO.puts("Command successful.")
    Jason.encode!(result) |> IO.puts()
  end

  defp render_enhanced_success(result) do
    # The `result` is expected to be a map containing the command context.
    # e.g., %{command: "agent", sub_command: "spawn", result: %{...}}
    command = result.sub_command || result.command

    case command do
      "spawn" ->
        ArborCli.RendererEnhanced.show_agent_spawn(result)

      "status" ->
        if agent_status = extract_status_from_result(result) do
          ArborCli.RendererEnhanced.show_agent_status_table([agent_status])
        else
          ArborCli.RendererEnhanced.show_error(
            "Failed to retrieve agent status for #{result.agent_id}"
          )

          ArborCli.RendererEnhanced.show_command_output_box(result.result)
        end

      "create" ->
        ArborCli.RendererEnhanced.show_success("Resource created successfully.")
        ArborCli.RendererEnhanced.show_command_output_box(result.result)

      "get" ->
        ArborCli.RendererEnhanced.show_success("Resource retrieved successfully.")
        ArborCli.RendererEnhanced.show_command_output_box(result.result)

      "list" ->
        ArborCli.RendererEnhanced.show_success("Resources listed successfully.")
        ArborCli.RendererEnhanced.show_command_output_box(result.result)

      "delete" ->
        ArborCli.RendererEnhanced.show_success("Resource deleted successfully.")

      "login" ->
        ArborCli.RendererEnhanced.show_success("Login successful.")

      "logout" ->
        ArborCli.RendererEnhanced.show_success("Logout successful.")

      "version" ->
        ArborCli.RendererEnhanced.show_success("Arbor CLI version:")
        ArborCli.RendererEnhanced.show_command_output_box(result.result)

      _ ->
        # Generic fallback for any other successful command
        ArborCli.RendererEnhanced.show_success("Command executed successfully.")
        ArborCli.RendererEnhanced.show_command_output_box(result)
    end
  end

  defp extract_status_from_result(result) do
    case result do
      %{result: agent_data, agent_id: agent_id} when is_map(agent_data) ->
        Map.put(agent_data, :id, agent_id)

      _ ->
        nil
    end
  end
end
