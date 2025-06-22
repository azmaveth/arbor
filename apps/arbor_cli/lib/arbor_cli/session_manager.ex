defmodule ArborCli.SessionManager do
  @moduledoc """
  Session lifecycle management for the CLI.

  Handles session creation, tracking, and cleanup for CLI commands.
  Provides a simpler interface than the full Gateway client for
  basic session operations.
  """

  use GenServer
  require Logger

  @doc """
  Start the session manager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get session statistics.
  """
  @spec get_stats() :: {:ok, map()}
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # GenServer callbacks

  @impl GenServer
  def init(_opts) do
    state = %{
      sessions_created: 0,
      active_sessions: %{},
      start_time: DateTime.utc_now()
    }

    Logger.info("Session manager started")
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_stats, _from, state) do
    stats = %{
      sessions_created: state.sessions_created,
      active_sessions: map_size(state.active_sessions),
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.start_time)
    }

    {:reply, {:ok, stats}, state}
  end

  @impl GenServer
  def handle_info({:session_created, session_id}, state) do
    new_sessions = Map.put(state.active_sessions, session_id, DateTime.utc_now())
    new_state = %{
      state |
      sessions_created: state.sessions_created + 1,
      active_sessions: new_sessions
    }

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:session_ended, session_id}, state) do
    new_sessions = Map.delete(state.active_sessions, session_id)
    new_state = %{state | active_sessions: new_sessions}

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end