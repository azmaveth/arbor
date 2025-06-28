defmodule ArborCli do
  @moduledoc """
  Arbor CLI - Command line interface for the Arbor agent orchestration system.

  This module provides the main entry point for the CLI application and defines
  the core CLI structure for interacting with the Arbor distributed agent system.

  ## Usage

      arbor agent spawn code_analyzer --name my-analyzer
      arbor agent list --filter '{"type": "code_analyzer"}'
      arbor agent status my-analyzer
      arbor agent exec my-analyzer analyze /path/to/file.ex

  ## Architecture

  The CLI follows a command-subcommand structure:
  - `arbor` - Main CLI entry point
  - `agent` - Agent management commands
    - `spawn` - Create new agents
    - `list` - List active agents
    - `status` - Get agent status
    - `exec` - Execute agent commands

  The CLI connects to the Arbor Gateway API to manage sessions and execute commands
  across the distributed agent cluster.
  """

  @doc """
  Application version.
  """
  @spec version() :: String.t()
  def version, do: "0.1.0"

  @doc """
  Get the default Gateway endpoint.
  """
  @spec default_gateway_endpoint() :: String.t()
  def default_gateway_endpoint do
    Application.get_env(:arbor_cli, :gateway_endpoint, "http://localhost:4000")
  end

  @doc """
  Get CLI configuration.
  """
  @spec config() :: %{
          gateway_endpoint: String.t(),
          timeout: non_neg_integer(),
          output_format: atom(),
          verbose: boolean()
        }
  def config do
    %{
      gateway_endpoint: default_gateway_endpoint(),
      timeout: Application.get_env(:arbor_cli, :timeout, 30_000),
      output_format: Application.get_env(:arbor_cli, :output_format, :table),
      verbose: Application.get_env(:arbor_cli, :verbose, false)
    }
  end
end
