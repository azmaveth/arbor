defmodule ArborCli.GatewayClient.EventStream do
  @moduledoc """
  Event streaming for real-time execution updates.

  Provides a stream interface for receiving execution events
  from the Gateway, allowing CLI commands to show real-time progress.
  """

  alias ArborCli.GatewayClient.Connection

  require Logger

  @doc """
  Create an event stream for an execution.
  """
  @spec create(pid(), String.t()) :: Enumerable.t()
  def create(conn, execution_id) do
    # Create a stream that polls the execution status
    Stream.resource(
      fn -> {execution_id, 0} end,
      fn
        {exec_id, _} = acc ->
          case get_execution_status(conn, exec_id) do
            {:ok, status} when status.status in [:completed, :failed] ->
              # End stream on completion or failure
              {:halt, acc}

            {:ok, status} ->
              # Continue streaming while in progress
              {[status], {exec_id, status.progress || 0}}

            {:error, reason} ->
              Logger.error("Failed to get execution status",
                execution_id: exec_id,
                reason: reason
              )
              {:halt, acc}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Subscribe to execution events via WebSocket.
  """
  @spec subscribe(pid(), String.t()) :: {:ok, pid()} | {:error, any()}
  def subscribe(_conn, execution_id) do
    ws_url = String.replace(Application.get_env(:arbor_cli, :gateway_endpoint), "http", "ws")

    WebSockex.start_link(
      "#{ws_url}/executions/#{execution_id}/events",
      __MODULE__.WebSocket,
      %{parent: self()}
    )
  end

  # Private functions

  defp get_execution_status(conn, execution_id) do
    case Connection.request(conn, :get, "/executions/#{execution_id}") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body, keys: :atoms)}

      {:ok, %{status: status, body: body}} ->
        error = Jason.decode!(body)
        {:error, {status, error["error"]}}

      {:error, _reason} = error ->
        error
    end
  end
end

defmodule ArborCli.GatewayClient.EventStream.WebSocket do
  @moduledoc false
  use WebSockex

  @spec handle_frame({:text, String.t()}, map()) :: {:ok, map()}
  def handle_frame({:text, msg}, state) do
    send(state.parent, {:execution_event, Jason.decode!(msg, keys: :atoms)})
    {:ok, state}
  end

  @spec handle_disconnect(map(), map()) :: {:ok, map()}
  def handle_disconnect(%{reason: reason}, state) do
    send(state.parent, {:execution_disconnected, reason})
    {:ok, state}
  end
end
