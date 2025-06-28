defmodule Arbor.Core.GatewayHTTP do
  @moduledoc """
  HTTP API router for the Arbor Gateway.

  Exposes Gateway functionality via RESTful HTTP endpoints.
  """

  @behaviour Arbor.Contracts.Gateway.GatewayHTTP

  use Plug.Router
  require Logger

  plug(Plug.Logger)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  # =====================================================
  # GatewayHTTP Behaviour Callbacks
  # =====================================================

  @impl Arbor.Contracts.Gateway.GatewayHTTP
  @spec handle_request(request :: any(), context :: map()) ::
          {:ok, binary()} | {:error, any()}
  def handle_request(request, context) do
    # Convert HTTP request to Gateway request format
    gateway_request = %{
      type: :command,
      payload: request
    }

    Arbor.Core.Gateway.handle_request(gateway_request, context)
  end

  @impl Arbor.Contracts.Gateway.GatewayHTTP
  @spec validate_request(request :: any()) :: :ok | {:error, :invalid_http_request}
  def validate_request(request) do
    # Basic HTTP request validation
    case request do
      %Plug.Conn{} -> :ok
      _ -> {:error, :invalid_http_request}
    end
  end

  # Session Management

  post "/sessions" do
    metadata = Map.get(conn.body_params, "metadata", %{})

    case Arbor.Core.Gateway.create_session(metadata: metadata) do
      {:ok, session_info} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, Jason.encode!(session_info))

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  get "/sessions/:session_id" do
    case Arbor.Core.Sessions.Manager.get_session_info(session_id) do
      {:ok, session_info} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(session_info))

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "Session not found"}))
    end
  end

  delete "/sessions/:session_id" do
    case Arbor.Core.Gateway.end_session(session_id) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "Session not found"}))

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  # Command Execution

  post "/commands" do
    session_id = List.first(get_req_header(conn, "x-session-id"))

    if is_nil(session_id) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "Missing session ID header"}))
    else
      command = conn.body_params

      case Arbor.Core.Gateway.execute_command(command, %{session_id: session_id}, nil) do
        {:ok, execution_id} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(202, Jason.encode!(%{execution_id: execution_id}))

        {:error, :session_not_found} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(404, Jason.encode!(%{error: "Session not found"}))

        {:error, reason} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{error: inspect(reason)}))
      end
    end
  end

  get "/executions/:execution_id" do
    case Arbor.Core.Gateway.get_execution_status(execution_id) do
      {:ok, status} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(status))

      {:error, :execution_not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "Execution not found"}))

      {:error, reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: inspect(reason)}))
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
