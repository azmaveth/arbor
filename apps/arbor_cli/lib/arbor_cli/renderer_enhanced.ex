defmodule ArborCli.RendererEnhanced do
  @moduledoc """
  Provides rich terminal UI rendering capabilities for Arbor CLI using the Owl library.

  This module offers a set of functions to display formatted output, including
  colored text, tables, boxes, and progress bars. It defines a consistent
  color scheme for different message types (e.g., success, error, info).

  The rendering functions are designed to gracefully degrade on terminals that
  do not support rich formatting, relying on Owl's built-in capabilities.
  """

  import Owl.Data, only: [tag: 2]
  import Owl.IO, only: [puts: 1]

  @color_scheme %{
    agent: :cyan,
    success: :green,
    error: :red,
    warning: :yellow,
    info: :blue,
    progress: :magenta
  }

  @doc """
  Displays feedback for an agent spawn command.

  ## Parameters
    - `result`: A map containing details of the spawned agent,
      typically `%{agent_type: "...", result: "agent-id-string"}`.

  ## Example
      iex> result = %{agent_type: "worker", result: "agent-123"}
      iex> ArborCli.RendererEnhanced.show_agent_spawn(result)
      # Displays a colored message indicating agent creation.
  """
  @spec show_agent_spawn(map()) :: :ok
  def show_agent_spawn(result) do
    agent_id = result.result # result contains the agent ID directly
    agent_type = result.agent_type

    [
      "Agent ",
      tag("spawned", @color_scheme.success),
      ": ",
      tag(ArborCli.FormatHelpers.format_agent_id(agent_id), @color_scheme.agent),
      " (type: #{agent_type})"
    ]
    |> puts()
  end

  @doc """
  Displays a list of agents in a formatted table.

  ## Parameters
    - `agents`: A list of agent maps, where each map contains at least
      `:id`, `:type`, and `:status`. An optional `:uptime` key can be included.

  ## Example
      iex> agents = [
      ...>   %{id: "agent-123", type: "worker", status: "active", uptime: "2h"},
      ...>   %{id: "agent-456", type: "monitor", status: "inactive"}
      ...> ]
      iex> ArborCli.RendererEnhanced.show_agent_status_table(agents)
      # Displays a table with agent information.
  """
  @spec show_agent_status_table([map()]) :: :ok
  def show_agent_status_table(agents) when is_list(agents) do
    if Enum.empty?(agents) do
      show_info("No agents found.")
    else
      headers = ["Agent ID", "Type", "Status", "Uptime"]

      rows =
        Enum.map(agents, fn agent ->
          [
            tag(ArborCli.FormatHelpers.format_agent_id(agent.id), @color_scheme.agent),
            agent.type,
            colorize_status(agent.status),
            agent.uptime || "N/A"
          ]
        end)

      Owl.Table.new(rows, headers) |> puts()
    end
  end

  @spec show_agent_status_table(any()) :: :ok
  def show_agent_status_table(_), do: show_error("Invalid agent list provided.")

  @doc """
  Displays a progress bar.

  This is useful for showing the progress of long-running operations.

  ## Parameters
    - `current`: The current progress value.
    - `total`: The total value representing 100% completion.

  ## Example
      iex> ArborCli.RendererEnhanced.show_execution_progress(50, 100)
      # Displays a progress bar at 50%.
  """
  @spec show_execution_progress(number(), number()) :: :ok | nil
  def show_execution_progress(current, total)
      when is_number(current) and is_number(total) and total > 0 do
    percentage = round(current / total * 100)
    progress_text = "Progress: #{current}/#{total} (#{percentage}%)"

    # Use IO.write for progress updates to stderr
    IO.write(:stderr, "\r#{progress_text}")

    # When progress is complete, print a newline to move to the next line.
    if current >= total do
      IO.write(:stderr, "\n")
    end
  end

  @spec show_execution_progress(any(), any()) :: nil
  def show_execution_progress(_, _), do: nil

  @doc """
  Displays command output inside a formatted box.

  ## Parameters
    - `output`: The string or data to display inside the box. If not a string,
      it will be inspected.

  ## Example
      iex> ArborCli.RendererEnhanced.show_command_output_box("Command executed successfully.")
      # Displays the text inside a box with a title.
  """
  @spec show_command_output_box(any()) :: :ok
  def show_command_output_box(output) do
    content = if is_binary(output), do: output, else: Kernel.inspect(output)

    Owl.Box.new(content, title: "Command Output", border: :heavy)
    |> puts()
  end

  @doc """
  Displays an error message with semantic coloring.
  """
  @spec show_error(any()) :: :ok
  def show_error(message) do
    ["[ERROR] ", to_string(message)]
    |> tag(@color_scheme.error)
    |> puts()
  end

  @doc """
  Displays a success message with semantic coloring.
  """
  @spec show_success(any()) :: :ok
  def show_success(message) do
    ["[SUCCESS] ", to_string(message)]
    |> tag(@color_scheme.success)
    |> puts()
  end

  @doc """
  Displays an informational message with semantic coloring.
  """
  @spec show_info(any()) :: :ok
  def show_info(message) do
    ["[INFO] ", to_string(message)]
    |> tag(@color_scheme.info)
    |> puts()
  end

  @doc """
  Displays a warning message with semantic coloring.
  """
  @spec show_warning(any()) :: :ok
  def show_warning(message) do
    ["[WARNING] ", to_string(message)]
    |> tag(@color_scheme.warning)
    |> puts()
  end

  # Private helpers

  @spec colorize_status(String.t() | any()) :: any()
  defp colorize_status("active"), do: tag("active", :green)
  defp colorize_status("inactive"), do: tag("inactive", :yellow)
  defp colorize_status("error"), do: tag("error", :red)
  defp colorize_status(status) when is_binary(status), do: status
  defp colorize_status(status), do: to_string(status)
end
