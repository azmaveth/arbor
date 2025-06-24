defmodule ArborCli.GatewayClient.Connection do
  @moduledoc """
  Connection pool management for Gateway client.

  Manages HTTP connections to the Arbor Gateway, including
  connection pooling, retry logic, and error handling.
  """

  require Logger

  @doc """
  Start the connection pool.
  """
  @spec start_pool(map()) :: {:ok, pid()} | {:error, any()}
  def start_pool(config) do
    with {:ok, endpoint} <- Map.fetch(config, :gateway_endpoint),
         {:ok, pool_size} <- Map.fetch(config, :connection_pool_size) do
      Logger.info("Starting connection pool",
        endpoint: endpoint,
        pool_size: pool_size
      )

      # For now, just return a mock pool PID
      # In a real implementation, this would start an HTTP connection pool
      pid = spawn(fn ->
        Process.sleep(:infinity)
      end)

      {:ok, pid}
    else
      :error ->
        Logger.error("Failed to start connection pool due to missing configuration")
        {:error, :missing_configuration}
    end
  end

  @doc """
  Make an HTTP request using the connection pool.
  """
  @spec request(pid(), atom(), String.t(), binary() | nil, list()) :: {:ok, map()} | {:error, map()}
  def request(_pool, method, path, body \\ nil, headers \\ []) do
    Logger.debug("Making HTTP request",
      method: method,
      path: path,
      body_size: if(body, do: byte_size(body), else: 0)
    )

    url = endpoint() <> path
    headers = [{"content-type", "application/json"} | headers]

    case HTTPoison.request(method, url, body || "", headers) do
      {:ok, %{status_code: status, body: resp_body}} ->
        {:ok, %{
          status: status,
          body: resp_body
        }}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, %{
          status: 500,
          body: Jason.encode!(%{error: inspect(reason)})
        }}
    end
  end

  defp endpoint do
    Application.get_env(:arbor_cli, :gateway_endpoint, "http://localhost:4000")
  end
end
