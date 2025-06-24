defmodule ArborCli.GatewayClient.Session do
  @moduledoc """
  Session management for Gateway client.

  Handles session lifecycle, command execution, and communication
  with the Arbor Gateway API.
  """

  require Logger

  alias ArborCli.GatewayClient.Connection

  @doc """
  Create a new session with the Gateway.
  """
  @spec create(pid(), keyword()) :: {:ok, map()} | {:error, any()}
  def create(conn, opts) do
    Logger.info("Creating session through Gateway HTTP API")

    body = %{
      metadata: Keyword.get(opts, :metadata, %{}),
      timeout: Keyword.get(opts, :timeout, 3_600_000)
    }

    case Connection.request(conn, :post, "/sessions", Jason.encode!(body)) do
      {:ok, %{status: 201, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status, body: body}} ->
        error = Jason.decode!(body)
        Logger.error("Failed to create Gateway session", status: status, error: error)
        {:error, error["error"]}

      {:error, _reason} = error ->
        Logger.error("HTTP request failed", reason: error)
        error
    end
  end

  @doc """
  End a session.
  """
  @spec end_session(pid(), String.t()) :: :ok | {:error, any()}
  def end_session(conn, session_id) do
    Logger.info("Ending session through Gateway HTTP API", session_id: session_id)

    case Connection.request(conn, :delete, "/sessions/#{session_id}") do
      {:ok, %{status: 204}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        error = Jason.decode!(body)
        Logger.error("Failed to end Gateway session",
          session_id: session_id,
          status: status,
          error: error
        )
        {:error, error["error"]}

      {:error, _reason} = error ->
        Logger.error("HTTP request failed", reason: error)
        error
    end
  end

  @doc """
  Discover capabilities for a session.
  """
  @spec discover_capabilities(pid(), String.t()) :: {:ok, [map()]}
  def discover_capabilities(_connection_pool, _session_id) do
    # Return simulated capabilities
    capabilities = [
      %{
        name: "spawn_agent",
        description: "Spawn a new agent",
        parameters: [
          %{name: "type", type: :atom, required: true},
          %{name: "id", type: :string, required: false},
          %{name: "working_dir", type: :string, required: false}
        ]
      },
      %{
        name: "query_agents",
        description: "Query active agents",
        parameters: [
          %{name: "filter", type: :map, required: false}
        ]
      },
      %{
        name: "get_agent_status",
        description: "Get agent status",
        parameters: [
          %{name: "agent_id", type: :string, required: true}
        ]
      },
      %{
        name: "execute_agent_command",
        description: "Execute agent command",
        parameters: [
          %{name: "agent_id", type: :string, required: true},
          %{name: "command", type: :string, required: true},
          %{name: "args", type: :list, required: false}
        ]
      }
    ]

    {:ok, capabilities}
  end

  @doc """
  Execute a command through the session.
  """
  @spec execute_command(pid(), String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, any()}
  def execute_command(_connection_pool, session_id, command, _opts) do
    Logger.info("Executing command through Gateway",
      session_id: session_id,
      command: command.type
    )

    # Call the Gateway directly instead of using stub
    case GenServer.call(Arbor.Core.Gateway, {:execute, session_id, command.type, command.params}) do
      {:async, execution_id} ->
        {:ok, execution_id}
      {:ok, execution_id} ->
        {:ok, execution_id}
      {:error, reason} = error ->
        Logger.error("Gateway command execution failed", reason: reason)
        error
    end
  end

  @doc """
  Get execution status.
  """
  @spec get_execution_status(pid(), String.t()) :: {:ok, map()}
  def get_execution_status(_connection_pool, execution_id) do
    # In a real implementation, this would query the Gateway
    # For now, return a simulated status
    {:ok, %{
      execution_id: execution_id,
      status: :executing,
      progress: 50,
      result: nil,
      error: nil
    }}
  end

  @doc """
  Wait for command execution to complete.
  """
  @spec wait_for_completion(pid(), String.t()) :: {:ok, any()} | {:error, any()}
  def wait_for_completion(_connection_pool, execution_id) do
    Logger.info("Waiting for execution completion", execution_id: execution_id)

    # Call the Gateway to wait for completion
    case GenServer.call(Arbor.Core.Gateway, {:wait_for_completion, execution_id}) do
      {:ok, result} ->
        {:ok, result}
      {:error, reason} = error ->
        Logger.error("Failed to wait for completion", execution_id: execution_id, reason: reason)
        error
    end
  end

  @doc """
  Cancel an execution.
  """
  @spec cancel_execution(pid(), String.t(), String.t()) :: :ok
  def cancel_execution(_connection_pool, execution_id, reason) do
    Logger.info("Execution cancelled",
      execution_id: execution_id,
      reason: reason
    )
    :ok
  end
end
