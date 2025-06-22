defmodule ArborCli.Renderer do
  @moduledoc """
  Output rendering and formatting for the Arbor CLI.

  Provides consistent formatting for command results, errors, and progress
  information across different output formats (table, JSON, YAML).
  """

  require Logger

  @doc """
  Render a successful command result.
  """
  def render_success(result) do
    format = Application.get_env(:arbor_cli, :output_format, :table)
    verbose = Application.get_env(:arbor_cli, :verbose, false)

    case format do
      :json -> render_json(result)
      :yaml -> render_yaml(result)
      :table -> render_table(result)
      _ -> render_table(result)
    end

    if verbose do
      render_execution_info(result)
    end
  end

  @doc """
  Render an error result.
  """
  def render_error(error) do
    case error do
      {:session_creation_failed, reason} ->
        IO.puts(:stderr, "❌ Failed to create session: #{format_error(reason)}")

      {:command_failed, reason} ->
        IO.puts(:stderr, "❌ Command failed: #{format_error(reason)}")

      {:spawn_failed, reason} ->
        IO.puts(:stderr, "❌ Agent spawn failed: #{format_error(reason)}")

      {:list_failed, reason} ->
        IO.puts(:stderr, "❌ Agent list failed: #{format_error(reason)}")

      {:status_failed, reason} ->
        IO.puts(:stderr, "❌ Agent status failed: #{format_error(reason)}")

      {:exec_failed, reason} ->
        IO.puts(:stderr, "❌ Agent command execution failed: #{format_error(reason)}")

      {:invalid_args, message, args} ->
        IO.puts(:stderr, "❌ Invalid arguments: #{message}")
        IO.puts(:stderr, "   Provided: #{inspect(args)}")

      {:unknown_subcommand, subcommand} ->
        IO.puts(:stderr, "❌ Unknown subcommand: #{subcommand}")

      {:unknown_command, command} ->
        IO.puts(:stderr, "❌ Unknown command: #{command}")

      other ->
        IO.puts(:stderr, "❌ Error: #{format_error(other)}")
    end
  end

  @doc """
  Render an exception.
  """
  def render_exception(exception) do
    IO.puts(:stderr, "💥 Unexpected error occurred:")
    IO.puts(:stderr, "   #{Exception.format(:error, exception, [])}")
    
    if Application.get_env(:arbor_cli, :verbose, false) do
      IO.puts(:stderr, "")
      IO.puts(:stderr, "Stack trace:")
      IO.puts(:stderr, Exception.format_stacktrace(Process.info(self(), :current_stacktrace)))
    end
  end

  # Format-specific renderers

  defp render_json(result) do
    result
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  defp render_yaml(result) do
    # Simple YAML-like output
    # In a real implementation, you'd use a YAML library
    IO.puts("---")
    render_yaml_value(result, 0)
  end

  defp render_table(result) do
    case result.action do
      "spawn" -> render_spawn_table(result)
      "list" -> render_list_table(result)
      "status" -> render_status_table(result)
      "exec" -> render_exec_table(result)
      _ -> render_generic_table(result)
    end
  end

  # Table renderers for specific commands

  defp render_spawn_table(result) do
    IO.puts("✅ Agent spawned successfully")
    IO.puts("")
    
    data = [
      ["Field", "Value"],
      ["Agent Type", result.agent_type],
      ["Agent ID", get_in(result, [:result, :result, :agent_id]) || "Unknown"],
      ["Status", get_in(result, [:result, :result, :status]) || "Unknown"],
      ["Working Dir", get_in(result, [:result, :result, :working_dir]) || "N/A"]
    ]

    render_simple_table(data)
  end

  defp render_list_table(result) do
    agents = get_in(result, [:result, :result, :agents]) || []
    total = get_in(result, [:result, :result, :total_agents]) || 0

    if total == 0 do
      IO.puts("📋 No agents found")
    else
      IO.puts("📋 Found #{total} agent(s)")
      IO.puts("")

      headers = ["Agent ID", "Type", "Status", "Node"]
      rows = Enum.map(agents, fn agent ->
        [
          agent[:id] || "Unknown",
          agent[:type] || "Unknown", 
          agent[:status] || "Unknown",
          agent[:node] || "Unknown"
        ]
      end)

      render_simple_table([headers | rows])
    end
  end

  defp render_status_table(result) do
    status_data = get_in(result, [:result, :result])

    if status_data do
      IO.puts("📊 Agent Status")
      IO.puts("")

      data = [
        ["Field", "Value"],
        ["Agent ID", result.agent_id],
        ["Status", status_data[:status] || "Unknown"],
        ["PID", status_data[:pid] || "N/A"],
        ["Node", status_data[:node] || "Unknown"]
      ]

      render_simple_table(data)
    else
      IO.puts("❌ No status data available")
    end
  end

  defp render_exec_table(result) do
    exec_result = get_in(result, [:result, :result, :result])

    IO.puts("🚀 Command executed successfully")
    IO.puts("")
    IO.puts("Command: #{result.command}")
    IO.puts("Agent: #{result.agent_id}")
    
    if result.args && length(result.args) > 0 do
      IO.puts("Arguments: #{Enum.join(result.args, " ")}")
    end

    IO.puts("")

    case exec_result do
      %{} = data when is_map(data) ->
        IO.puts("Result:")
        render_nested_data(data, 2)

      other ->
        IO.puts("Result: #{inspect(other)}")
    end
  end

  defp render_generic_table(result) do
    IO.puts("✅ Command completed")
    IO.puts("")
    IO.puts(inspect(result, pretty: true))
  end

  # Helper functions

  defp render_simple_table(rows) do
    # Simple table rendering without external dependencies
    if length(rows) > 0 do
      # Calculate column widths
      widths = rows
        |> Enum.reduce([], fn row, acc ->
          row
          |> Enum.with_index()
          |> Enum.map(fn {cell, idx} ->
            current_width = String.length(to_string(cell))
            case Enum.at(acc, idx) do
              nil -> current_width
              existing -> max(existing, current_width)
            end
          end)
        end)

      # Render rows
      rows
      |> Enum.with_index()
      |> Enum.each(fn {row, idx} ->
        formatted_row = row
          |> Enum.with_index()
          |> Enum.map(fn {cell, col_idx} ->
            width = Enum.at(widths, col_idx, 0)
            String.pad_trailing(to_string(cell), width)
          end)
          |> Enum.join("  ")

        IO.puts(formatted_row)

        # Add separator after header
        if idx == 0 and length(rows) > 1 do
          separator = widths
            |> Enum.map(fn width -> String.duplicate("-", width) end)
            |> Enum.join("  ")
          IO.puts(separator)
        end
      end)
    end
  end

  defp render_nested_data(data, indent) when is_map(data) do
    Enum.each(data, fn {key, value} ->
      prefix = String.duplicate(" ", indent)
      case value do
        %{} = nested ->
          IO.puts("#{prefix}#{key}:")
          render_nested_data(nested, indent + 2)
        list when is_list(list) ->
          IO.puts("#{prefix}#{key}: #{inspect(list)}")
        other ->
          IO.puts("#{prefix}#{key}: #{other}")
      end
    end)
  end

  defp render_nested_data(data, indent) when is_list(data) do
    prefix = String.duplicate(" ", indent)
    Enum.each(data, fn item ->
      IO.puts("#{prefix}- #{inspect(item)}")
    end)
  end

  defp render_nested_data(data, indent) do
    prefix = String.duplicate(" ", indent)
    IO.puts("#{prefix}#{inspect(data)}")
  end

  defp render_yaml_value(value, indent) when is_map(value) do
    prefix = String.duplicate("  ", indent)
    Enum.each(value, fn {key, val} ->
      IO.puts("#{prefix}#{key}:")
      render_yaml_value(val, indent + 1)
    end)
  end

  defp render_yaml_value(value, indent) when is_list(value) do
    prefix = String.duplicate("  ", indent)
    Enum.each(value, fn item ->
      IO.puts("#{prefix}- #{inspect(item)}")
    end)
  end

  defp render_yaml_value(value, indent) do
    prefix = String.duplicate("  ", indent)
    IO.puts("#{prefix}#{inspect(value)}")
  end

  defp render_execution_info(result) do
    IO.puts("")
    IO.puts("🔍 Execution Details:")
    
    if execution_id = get_in(result, [:execution_id]) do
      IO.puts("  Execution ID: #{execution_id}")
    end
    
    if session_id = get_in(result, [:session_id]) do
      IO.puts("  Session ID: #{session_id}")
    end
  end

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(error), do: inspect(error)
end