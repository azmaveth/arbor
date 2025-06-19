defmodule Arbor.Core.Application do
  @moduledoc """
  Main application supervisor for Arbor Core.

  Sets up the supervision tree for the core Arbor system including:
  - Distributed process management (Horde)
  - Event broadcasting (Phoenix PubSub)
  - Session management
  - Gateway services
  - Telemetry reporting

  The supervision strategy is designed for fault tolerance with automatic
  restart capabilities while maintaining system consistency.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Arbor Core Application")

    children = [
      # Distributed process management
      {Horde.Registry, [name: Arbor.Core.Registry, keys: :unique]},
      {Horde.DynamicSupervisor,
       [
         name: Arbor.Core.AgentSupervisor,
         strategy: :one_for_one
       ]},

      # Event broadcasting
      {Phoenix.PubSub, name: Arbor.PubSub},

      # Task supervision for async operations
      {Task.Supervisor, name: Arbor.TaskSupervisor},

      # Core services
      Arbor.Core.Sessions.Manager,
      Arbor.Core.Gateway,

      # Telemetry (placeholder for now)
      {Task, fn -> setup_telemetry() end}
    ]

    opts = [strategy: :one_for_one, name: Arbor.Core.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Arbor Core Application started successfully")

        # Emit startup telemetry
        :telemetry.execute(
          [:arbor, :application, :start],
          %{count: 1},
          %{node: Node.self()}
        )

        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start Arbor Core Application", reason: reason)
        {:error, reason}
    end
  end

  @impl true
  def stop(_state) do
    Logger.info("Stopping Arbor Core Application")

    # Emit shutdown telemetry
    :telemetry.execute(
      [:arbor, :application, :stop],
      %{count: 1},
      %{node: Node.self()}
    )

    :ok
  end

  # Private functions

  defp setup_telemetry do
    # Define telemetry events for the system
    events = [
      [:arbor, :application, :start],
      [:arbor, :application, :stop],
      [:arbor, :gateway, :start],
      [:arbor, :gateway, :session, :created],
      [:arbor, :gateway, :command, :started],
      [:arbor, :gateway, :command, :completed],
      [:arbor, :gateway, :command, :failed],
      [:arbor, :session_manager, :start],
      [:arbor, :session, :created],
      [:arbor, :session, :start],
      [:arbor, :session, :stop],
      [:arbor, :session, :ended],
      [:arbor, :session, :capability, :granted]
    ]

    # Log telemetry events for development
    :telemetry.attach_many(
      "arbor-logger",
      events,
      &handle_telemetry_event/4,
      nil
    )

    Logger.info("Telemetry setup completed", events_count: length(events))
  end

  defp handle_telemetry_event(event_name, measurements, metadata, _config) do
    Logger.debug("Telemetry event",
      event: event_name,
      measurements: measurements,
      metadata: metadata
    )
  end
end
