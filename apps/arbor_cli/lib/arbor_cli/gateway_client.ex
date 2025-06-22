defmodule ArborCli.GatewayClient do
  @moduledoc """
  Gateway API client for the Arbor CLI.

  Provides a high-level interface for communicating with the Arbor Gateway,
  including session management, command execution, and event subscription.

  ## Features

  - Session creation and lifecycle management
  - Asynchronous command execution with progress tracking
  - Connection pooling for performance
  - Automatic retry and error handling
  - Event streaming for real-time updates

  ## Usage

      # Create a session
      {:ok, session_id} = GatewayClient.create_session()

      # Execute a command
      {:ok, execution_id} = GatewayClient.execute_command(session_id, command)

      # Wait for completion or stream events
      {:ok, result} = GatewayClient.wait_for_completion(execution_id)
  """

  use GenServer
  require Logger

  alias ArborCli.GatewayClient.{Connection, EventStream, Session}

  @typedoc "Client configuration"
  @type config :: %{
          gateway_endpoint: String.t(),
          timeout: non_neg_integer(),
          retry_attempts: non_neg_integer(),
          connection_pool_size: non_neg_integer()
        }

  @typedoc "Session information"
  @type session_info :: %{
          session_id: String.t(),
          created_at: DateTime.t(),
          capabilities: [map()],
          metadata: map()
        }

  @typedoc "Command execution information"
  @type execution_info :: %{
          execution_id: String.t(),
          status: :executing | :completed | :failed | :cancelled,
          progress: non_neg_integer() | nil,
          result: any() | nil,
          error: any() | nil
        }

  # Client API

  @doc """
  Start the Gateway client.
  """
  @spec start_link(config()) :: GenServer.on_start()
  def start_link(config \\ %{}) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Create a new session with the Gateway.

  ## Options

  - `:metadata` - Session metadata
  - `:client_type` - Type of client (defaults to :cli)

  ## Returns

  - `{:ok, session_info()}` - Session created successfully
  - `{:error, reason}` - Session creation failed
  """
  @spec create_session(keyword()) :: {:ok, session_info()} | {:error, term()}
  def create_session(opts \\ []) do
    GenServer.call(__MODULE__, {:create_session, opts})
  end

  @doc """
  End a session and clean up resources.
  """
  @spec end_session(String.t()) :: :ok | {:error, term()}
  def end_session(session_id) do
    GenServer.call(__MODULE__, {:end_session, session_id})
  end

  @doc """
  Discover capabilities available to a session.
  """
  @spec discover_capabilities(String.t()) :: {:ok, [map()]} | {:error, term()}
  def discover_capabilities(session_id) do
    GenServer.call(__MODULE__, {:discover_capabilities, session_id})
  end

  @doc """
  Execute a command asynchronously.

  ## Parameters

  - `session_id` - Session identifier
  - `command` - Command structure with type and params
  - `opts` - Execution options

  ## Returns

  - `{:ok, execution_id}` - Command started successfully
  - `{:error, reason}` - Command execution failed
  """
  @spec execute_command(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def execute_command(session_id, command, opts \\ []) do
    GenServer.call(__MODULE__, {:execute_command, session_id, command, opts})
  end

  @doc """
  Get execution status.
  """
  @spec get_execution_status(String.t()) :: {:ok, execution_info()} | {:error, term()}
  def get_execution_status(execution_id) do
    GenServer.call(__MODULE__, {:get_execution_status, execution_id})
  end

  @doc """
  Wait for command execution to complete.

  Blocks until the execution completes, fails, or times out.
  """
  @spec wait_for_completion(String.t(), non_neg_integer()) :: {:ok, any()} | {:error, term()}
  def wait_for_completion(execution_id, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:wait_for_completion, execution_id}, timeout + 1000)
  end

  @doc """
  Subscribe to execution events for real-time progress updates.

  Returns a stream that yields execution events.
  """
  @spec stream_execution_events(String.t()) :: Enumerable.t()
  def stream_execution_events(execution_id) do
    EventStream.create(execution_id)
  end

  @doc """
  Cancel a running execution.
  """
  @spec cancel_execution(String.t(), String.t()) :: :ok | {:error, term()}
  def cancel_execution(execution_id, reason \\ "User cancelled") do
    GenServer.call(__MODULE__, {:cancel_execution, execution_id, reason})
  end

  # GenServer callbacks

  @impl GenServer
  def init(config) do
    # Merge with defaults
    full_config = Map.merge(default_config(), config)

    # Initialize connection pool
    case Connection.start_pool(full_config) do
      {:ok, pool_pid} ->
        state = %{
          config: full_config,
          connection_pool: pool_pid,
          active_sessions: %{},
          active_executions: %{}
        }

        Logger.info("Gateway client started",
          endpoint: full_config.gateway_endpoint,
          pool_size: full_config.connection_pool_size
        )

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to start Gateway client", reason: reason)
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:create_session, opts}, _from, state) do
    case Session.create(state.connection_pool, opts) do
      {:ok, session_info} ->
        new_sessions = Map.put(state.active_sessions, session_info.session_id, session_info)
        {:reply, {:ok, session_info}, %{state | active_sessions: new_sessions}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call({:end_session, session_id}, _from, state) do
    case Session.end_session(state.connection_pool, session_id) do
      :ok ->
        new_sessions = Map.delete(state.active_sessions, session_id)
        {:reply, :ok, %{state | active_sessions: new_sessions}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call({:discover_capabilities, session_id}, _from, state) do
    result = Session.discover_capabilities(state.connection_pool, session_id)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:execute_command, session_id, command, opts}, _from, state) do
    case Session.execute_command(state.connection_pool, session_id, command, opts) do
      {:ok, execution_id} ->
        execution_info = %{
          execution_id: execution_id,
          session_id: session_id,
          command: command,
          status: :executing,
          started_at: DateTime.utc_now()
        }

        new_executions = Map.put(state.active_executions, execution_id, execution_info)
        {:reply, {:ok, execution_id}, %{state | active_executions: new_executions}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_call({:get_execution_status, execution_id}, _from, state) do
    result = Session.get_execution_status(state.connection_pool, execution_id)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:wait_for_completion, execution_id}, _from, state) do
    result = Session.wait_for_completion(state.connection_pool, execution_id)

    # Clean up from active executions when complete
    new_executions = Map.delete(state.active_executions, execution_id)
    {:reply, result, %{state | active_executions: new_executions}}
  end

  @impl GenServer
  def handle_call({:cancel_execution, execution_id, reason}, _from, state) do
    result = Session.cancel_execution(state.connection_pool, execution_id, reason)

    # Clean up from active executions
    new_executions = Map.delete(state.active_executions, execution_id)
    {:reply, result, %{state | active_executions: new_executions}}
  end

  # Private functions

  @spec default_config() :: config()
  defp default_config do
    %{
      gateway_endpoint: ArborCli.default_gateway_endpoint(),
      timeout: 30_000,
      retry_attempts: 3,
      connection_pool_size: 10
    }
  end
end

# Connection Pool Supervisor
defmodule ArborCli.GatewayClient.Supervisor do
  @moduledoc """
  Supervisor for Gateway client components.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    children = [
      {ArborCli.GatewayClient, %{}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
