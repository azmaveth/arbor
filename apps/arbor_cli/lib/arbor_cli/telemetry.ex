defmodule ArborCli.Telemetry do
  @moduledoc """
  Telemetry collection for CLI usage metrics.

  Tracks CLI usage patterns, command execution times, and error rates
  to help improve the user experience.
  """

  use GenServer
  require Logger

  @doc """
  Start the telemetry collector.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # GenServer callbacks

  @impl GenServer
  def init(_opts) do
    # Attach telemetry handlers if metrics collection is enabled
    enabled = Application.get_env(:arbor_cli, :telemetry_enabled, false)

    if enabled do
      attach_handlers()
      Logger.info("CLI telemetry enabled")
    else
      Logger.debug("CLI telemetry disabled")
    end

    state = %{
      enabled: enabled,
      metrics: %{
        commands_executed: 0,
        sessions_created: 0,
        errors_encountered: 0
      }
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:telemetry_event, event_name, measurements, metadata}, state) do
    if state.enabled do
      handle_telemetry_event(event_name, measurements, metadata)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  @spec attach_handlers() :: :ok | {:error, :already_exists}
  defp attach_handlers do
    events = [
      [:arbor_cli, :command, :start],
      [:arbor_cli, :command, :stop],
      [:arbor_cli, :command, :exception],
      [:arbor_cli, :session, :created],
      [:arbor_cli, :session, :ended]
    ]

    :telemetry.attach_many(
      "arbor-cli-telemetry",
      events,
      &handle_telemetry_event/4,
      nil
    )
  end

  @spec handle_telemetry_event(list(atom()), map(), map(), any()) :: :ok
  defp handle_telemetry_event([:arbor_cli, :command, :start], _measurements, metadata, _config) do
    Logger.debug("Command started",
      command: metadata[:command],
      subcommand: metadata[:subcommand]
    )
  end

  @spec handle_telemetry_event(list(atom()), map(), map(), any()) :: :ok
  defp handle_telemetry_event([:arbor_cli, :command, :stop], measurements, metadata, _config) do
    Logger.info("Command completed",
      command: metadata[:command],
      duration_ms: measurements[:duration],
      result: metadata[:result]
    )
  end

  @spec handle_telemetry_event(list(atom()), map(), map(), any()) :: :ok
  defp handle_telemetry_event([:arbor_cli, :command, :exception], _measurements, metadata, _config) do
    Logger.error("Command failed with exception",
      command: metadata[:command],
      error: metadata[:error]
    )
  end

  @spec handle_telemetry_event(list(atom()), map(), map(), any()) :: :ok
  defp handle_telemetry_event([:arbor_cli, :session, :created], _measurements, metadata, _config) do
    Logger.debug("Session created", session_id: metadata[:session_id])
  end

  @spec handle_telemetry_event(list(atom()), map(), map(), any()) :: :ok
  defp handle_telemetry_event([:arbor_cli, :session, :ended], _measurements, metadata, _config) do
    Logger.debug("Session ended", session_id: metadata[:session_id])
  end

  @spec handle_telemetry_event(list(atom()), map(), map()) :: :ok
  defp handle_telemetry_event(event_name, measurements, metadata) do
    Logger.debug("Telemetry event received",
      event: event_name,
      measurements: measurements,
      metadata: metadata
    )
  end
end
