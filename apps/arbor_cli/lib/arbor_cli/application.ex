defmodule ArborCli.Application do
  @moduledoc """
  Application module for the Arbor CLI.

  Manages the supervision tree for CLI components including:
  - Gateway client connection pools
  - Session management
  - Background telemetry collection
  """

  use Application

  require Logger

  @impl Application
  def start(_type, _args) do
    children = [
      # Gateway client supervisor for connection pooling
      {ArborCli.GatewayClient.Supervisor, []},
      
      # Session manager for CLI session lifecycle
      {ArborCli.SessionManager, []},
      
      # Telemetry for CLI usage metrics (optional)
      {ArborCli.Telemetry, []}
    ]

    # Start supervision tree
    opts = [strategy: :one_for_one, name: ArborCli.Supervisor]
    
    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Arbor CLI application started", pid: inspect(pid))
        {:ok, pid}
        
      {:error, reason} = error ->
        Logger.error("Failed to start Arbor CLI application", reason: reason)
        error
    end
  end

  @impl Application
  def stop(_state) do
    Logger.info("Arbor CLI application stopped")
    :ok
  end
end