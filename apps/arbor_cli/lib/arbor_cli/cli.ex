defmodule ArborCli.CLI do
  @moduledoc """
  Main CLI entry point for the Arbor command-line interface.

  This module handles command-line argument parsing, routing to appropriate 
  command handlers, and coordinating the overall CLI execution flow.

  ## Command Structure

      arbor <command> <subcommand> [options] [args]

  Currently supported:
  - `arbor agent <subcommand>` - Agent management commands

  ## Options

  Global options available for all commands:
  - `--gateway <url>` - Gateway endpoint (default: http://localhost:4000)
  - `--format <format>` - Output format: table, json, yaml (default: table)
  - `--timeout <ms>` - Command timeout in milliseconds (default: 30000)
  - `--verbose` - Enable verbose output
  - `--help` - Show help information
  """

  @doc """
  Main entry point for the CLI application.

  This function is called by the escript when the `arbor` command is executed.
  """
  def main(args) do
    # Start the application if not already started
    Application.ensure_all_started(:arbor_cli)

    # Parse and execute the command
    args
    |> parse_args()
    |> execute_command()
    |> handle_result()
  rescue
    e ->
      handle_error(e)
      System.halt(1)
  end

  @doc """
  Parse command line arguments into a structured command.
  """
  def parse_args(args) do
    spec = command_spec()
    
    case Optimus.parse(spec, args) do
      {:ok, command_path, parsed} ->
        # Structure the result properly for execute_command
        %{
          command: command_path,
          args: parsed.args,
          options: parsed.options,
          flags: parsed.flags,
          unknown: parsed.unknown
        }
        
      :help ->
        print_help(spec)
        System.halt(0)
        
      :version ->
        IO.puts("arbor version #{ArborCli.version()}")
        System.halt(0)
        
      {:help, _command_path} ->
        print_help(spec)
        System.halt(0)
        
      {:error, command_path, errors} when is_list(errors) ->
        IO.puts(:stderr, "Errors for command '#{Enum.join(command_path, " ")}':")
        Enum.each(errors, &IO.puts(:stderr, "  #{&1}"))
        IO.puts(:stderr, "Use 'arbor --help' for usage information.")
        System.halt(1)
        
      {:error, {error_type, error_data}} ->
        print_error(error_type, error_data)
        print_help(spec)
        System.halt(1)
        
      other ->
        IO.puts(:stderr, "Unexpected parse result: #{inspect(other)}")
        print_help(spec)
        System.halt(1)
    end
  end

  @doc """
  Execute the parsed command.
  """
  def execute_command(parsed) do
    # Extract command components from Optimus ParseResult
    options = parsed.options
    flags = parsed.flags

    # Set global configuration
    set_global_config(options)

    # Handle the command structure from Optimus
    case parsed do
      %{command: [:agent, subcommand]} ->
        # Get the args for the specific subcommand
        args = case subcommand do
          :spawn -> [parsed.args[:type]]
          :status -> [parsed.args[:agent_id]]
          :exec -> [parsed.args[:agent_id], parsed.args[:command] | parsed.unknown]
          :list -> []
        end
        
        ArborCli.Commands.Agent.execute(subcommand, args, options)
        
      other ->
        {:error, {:unexpected_command_result, other}}
    end
  end

  @doc """
  Handle command execution results.
  """
  def handle_result({:ok, result}) do
    render_enhanced_success(result)
    System.halt(0)
  end

  def handle_result({:error, reason}) do
    render_enhanced_error(reason)
    System.halt(1)
  end

  @doc """
  Handle uncaught exceptions.
  """
  def handle_error(exception) do
    ArborCli.RendererEnhanced.show_error("Unexpected error occurred: #{Exception.message(exception)}")
    
    if Application.get_env(:arbor_cli, :verbose, false) do
      ArborCli.RendererEnhanced.show_command_output_box(Exception.format(:error, exception, []))
    end
  end

  # Enhanced rendering functions
  
  defp render_enhanced_success(result) do
    case result.action do
      "spawn" -> 
        ArborCli.RendererEnhanced.show_agent_spawn(result)
        
      "list" -> 
        agents = extract_agents_from_result(result)
        ArborCli.RendererEnhanced.show_agent_status_table(agents)
        
      "status" -> 
        if agent_status = extract_status_from_result(result) do
          ArborCli.RendererEnhanced.show_agent_status_table([agent_status])
        else
          ArborCli.RendererEnhanced.show_error("Failed to retrieve agent status for #{result.agent_id}")
          ArborCli.RendererEnhanced.show_command_output_box(result.result)
        end
        
      "exec" -> 
        ArborCli.RendererEnhanced.show_success("Command '#{result.command}' executed on agent #{result.agent_id}")
        if result.result do
          ArborCli.RendererEnhanced.show_command_output_box(result.result)
        end
        
      _ -> 
        ArborCli.RendererEnhanced.show_success("Command completed successfully")
        ArborCli.RendererEnhanced.show_command_output_box(result)
    end
  end
  
  defp render_enhanced_error(reason) do
    case reason do
      {:session_creation_failed, details} ->
        ArborCli.RendererEnhanced.show_error("Failed to create session: #{format_error(details)}")

      {:command_failed, details} ->
        ArborCli.RendererEnhanced.show_error("Command failed: #{format_error(details)}")

      {:spawn_failed, details} ->
        ArborCli.RendererEnhanced.show_error("Agent spawn failed: #{format_error(details)}")

      {:list_failed, details} ->
        ArborCli.RendererEnhanced.show_error("Agent list failed: #{format_error(details)}")

      {:status_failed, details} ->
        ArborCli.RendererEnhanced.show_error("Agent status failed: #{format_error(details)}")

      {:exec_failed, details} ->
        ArborCli.RendererEnhanced.show_error("Agent command execution failed: #{format_error(details)}")

      {:invalid_args, message, args} ->
        ArborCli.RendererEnhanced.show_error("Invalid arguments: #{message}")
        ArborCli.RendererEnhanced.show_info("Provided: #{inspect(args)}")

      {:unknown_subcommand, subcommand} ->
        ArborCli.RendererEnhanced.show_error("Unknown subcommand: #{subcommand}")

      {:unknown_command, command} ->
        ArborCli.RendererEnhanced.show_error("Unknown command: #{command}")

      other ->
        ArborCli.RendererEnhanced.show_error("Error: #{format_error(other)}")
    end
  end
  
  defp extract_agents_from_result(result) do
    agents = get_in(result, [:result, :result, :agents]) || []
    
    # Transform agents to match expected format for RendererEnhanced
    Enum.map(agents, fn agent ->
      %{
        id: agent[:id] || "Unknown",
        type: agent[:type] || "Unknown",
        status: agent[:status] || "Unknown",
        uptime: calculate_uptime(agent)
      }
    end)
  end
  
  defp extract_status_from_result(result) do
    status_data = get_in(result, [:result, :result])
    
    if status_data do
      %{
        id: result.agent_id,
        type: status_data[:type] || "Unknown",
        status: status_data[:status] || "Unknown",
        uptime: calculate_uptime(status_data)
      }
    else
      nil
    end
  end
  
  defp calculate_uptime(agent_data) when is_map(agent_data) do
    cond do
      start_time = agent_data[:started_at] ->
        if is_binary(start_time) do
          case DateTime.from_iso8601(start_time) do
            {:ok, datetime, _} -> ArborCli.FormatHelpers.format_time_ago(datetime)
            _ -> "Unknown"
          end
        else
          "Unknown"
        end
      
      uptime = agent_data[:uptime] ->
        if is_integer(uptime) do
          ArborCli.FormatHelpers.format_duration(uptime)
        else
          to_string(uptime)
        end
        
      true ->
        "N/A"
    end
  end
  
  defp calculate_uptime(_), do: "N/A"
  
  defp format_error(error) when is_binary(error), do: error
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)
  defp format_error(error), do: inspect(error)

  # Private functions

  defp command_spec do
    Optimus.new!(
      name: "arbor",
      description: "Arbor distributed agent orchestration CLI",
      version: ArborCli.version(),
      author: "Arbor Team",
      about: "Command-line interface for managing Arbor agents and sessions",
      allow_unknown_args: false,
      parse_double_dash: true,
      args: [],
      flags: [
        verbose: [
          short: "-v",
          long: "--verbose",
          help: "Enable verbose output",
          multiple: false
        ],
        help: [
          short: "-h",
          long: "--help",
          help: "Show help information",
          multiple: false
        ]
      ],
      options: [
        gateway: [
          short: "-g",
          long: "--gateway",
          help: "Gateway endpoint URL",
          parser: :string,
          default: ArborCli.default_gateway_endpoint()
        ],
        format: [
          short: "-f",
          long: "--format",
          help: "Output format (table, json, yaml)",
          parser: fn
            "table" -> {:ok, :table}
            "json" -> {:ok, :json}
            "yaml" -> {:ok, :yaml}
            other -> {:error, "Invalid format: #{other}"}
          end,
          default: :table
        ],
        timeout: [
          short: "-t",
          long: "--timeout",
          help: "Command timeout in milliseconds",
          parser: :integer,
          default: 30_000
        ]
      ],
      subcommands: [
        agent: [
          name: "agent",
          about: "Agent management commands",
          args: [],
          flags: [],
          options: [],
          subcommands: [
            spawn: [
              name: "spawn",
              about: "Spawn a new agent",
              args: [
                type: [
                  value_name: "TYPE",
                  help: "Agent type (e.g., code_analyzer)",
                  required: true,
                  parser: fn str -> {:ok, String.to_atom(str)} end
                ]
              ],
              flags: [],
              options: [
                name: [
                  long: "--name",
                  help: "Custom agent name",
                  parser: :string
                ],
                working_dir: [
                  long: "--working-dir",
                  help: "Working directory for the agent",
                  parser: :string
                ],
                metadata: [
                  long: "--metadata",
                  help: "Additional metadata as JSON",
                  parser: fn json_str ->
                    case Jason.decode(json_str) do
                      {:ok, data} -> {:ok, data}
                      {:error, _} -> {:error, "Invalid JSON metadata"}
                    end
                  end
                ]
              ]
            ],
            list: [
              name: "list",
              about: "List active agents",
              args: [],
              flags: [],
              options: [
                filter: [
                  long: "--filter",
                  help: "Filter criteria as JSON",
                  parser: fn json_str ->
                    case Jason.decode(json_str) do
                      {:ok, data} -> {:ok, data}
                      {:error, _} -> {:error, "Invalid JSON filter"}
                    end
                  end
                ]
              ]
            ],
            status: [
              name: "status", 
              about: "Get agent status",
              args: [
                agent_id: [
                  value_name: "AGENT_ID",
                  help: "Agent ID to query",
                  required: true,
                  parser: :string
                ]
              ],
              flags: [],
              options: []
            ],
            exec: [
              name: "exec",
              about: "Execute command on agent",
              args: [
                agent_id: [
                  value_name: "AGENT_ID", 
                  help: "Agent ID to command",
                  required: true,
                  parser: :string
                ],
                command: [
                  value_name: "COMMAND",
                  help: "Command to execute",
                  required: true,
                  parser: :string
                ]
              ],
              flags: [],
              options: [],
              allow_unknown_args: true  # Allow additional command arguments
            ]
          ]
        ]
      ]
    )
  end

  defp set_global_config(options) do
    # Update application configuration with CLI options
    if options[:gateway] do
      Application.put_env(:arbor_cli, :gateway_endpoint, options.gateway)
    end

    if options[:format] do
      Application.put_env(:arbor_cli, :output_format, options.format)
    end

    if options[:timeout] do
      Application.put_env(:arbor_cli, :timeout, options.timeout)
    end

    if options[:verbose] do
      Application.put_env(:arbor_cli, :verbose, true)
    end
  end

  defp print_error(error_type, error_data) do
    IO.puts(:stderr, "Error: #{error_type}")
    IO.puts(:stderr, "Details: #{inspect(error_data)}")
  end

  defp print_help(spec) do
    IO.puts(Optimus.help(spec))
  end
end