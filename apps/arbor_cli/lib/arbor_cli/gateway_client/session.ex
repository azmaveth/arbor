defmodule ArborCli.GatewayClient.Session do
  @moduledoc """
  Session management for Gateway client.

  Handles session lifecycle, command execution, and communication
  with the Arbor Gateway API.
  """

  require Logger

  @doc """
  Create a new session with the Gateway.
  """
  def create(_connection_pool, opts) do
    Logger.info("Creating session through Gateway")
    
    # Call the Gateway directly to create session
    case GenServer.call(Arbor.Core.Gateway, {:create_session, opts}) do
      {:ok, session_info} ->
        {:ok, session_info}
      {:error, reason} = error ->
        Logger.error("Failed to create Gateway session", reason: reason)
        error
    end
  end

  @doc """
  End a session.
  """
  def end_session(_connection_pool, session_id) do
    Logger.info("Ending session through Gateway", session_id: session_id)
    
    # Call the Gateway directly to end session
    case GenServer.call(Arbor.Core.Gateway, {:end_session, session_id}) do
      :ok ->
        :ok
      {:error, reason} = error ->
        Logger.error("Failed to end Gateway session", session_id: session_id, reason: reason)
        error
    end
  end

  @doc """
  Discover capabilities for a session.
  """
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
  def cancel_execution(_connection_pool, execution_id, reason) do
    Logger.info("Execution cancelled", 
      execution_id: execution_id, 
      reason: reason
    )
    :ok
  end

  # Private functions

  defp simulate_command_execution(execution_id, session_id, command) do
    Logger.info("Simulating command execution",
      execution_id: execution_id,
      session_id: session_id,
      command_type: command.type
    )

    # Simulate some processing time
    Process.sleep(2000)

    Logger.info("Command execution completed",
      execution_id: execution_id
    )
  end
end