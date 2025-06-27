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

  @behaviour Arbor.Contracts.Core.Application

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Arbor Core Application")

    # Get topology configuration for libcluster
    topologies = Application.get_env(:libcluster, :topologies, [])

    # Check if we should use Horde or mocks
    use_horde =
      case Application.get_env(:arbor_core, :registry_impl, :auto) do
        :mock ->
          false

        :horde ->
          true

        :auto ->
          # Check if we're in test environment
          Application.get_env(:arbor_core, :env, :prod) != :test
      end

    # Session registry configuration (only for non-mock environments)
    session_registry_children =
      if use_horde do
        [Arbor.Core.SessionRegistry]
      else
        []
      end

    # HTTP API (only in dev/prod)
    http_children =
      if Application.get_env(:arbor_core, :http_api, enabled: true)[:enabled] do
        [{Plug.Cowboy, scheme: :http, plug: Arbor.Core.GatewayHTTP, options: [port: 4000]}]
      else
        []
      end

    # Base children that always start
    base_children =
      [
        # Phoenix PubSub (needed by coordination)
        {Phoenix.PubSub, name: Arbor.Core.PubSub},

        # Task supervision for async operations
        {Task.Supervisor, name: Arbor.TaskSupervisor},

        # Core services
        Arbor.Core.Sessions.Manager,
        Arbor.Core.Gateway,

        # Telemetry (placeholder for now)
        {Task, fn -> setup_telemetry() end}
      ] ++ session_registry_children ++ http_children

    # Distributed components (only in production/dev with Horde)
    distributed_children =
      if use_horde do
        [
          # Cluster formation (must be first)
          {Cluster.Supervisor, [topologies, [name: Arbor.ClusterSupervisor]]},

          # Cluster management (coordinates Horde components)
          Arbor.Core.ClusterManager,

          # Distributed process management infrastructure (includes Registry + Supervisor + HordeSupervisor)
          %{
            id: Arbor.Core.HordeSupervisor,
            start: {Arbor.Core.HordeSupervisor, :start_supervisor, []},
            type: :supervisor
          },
          # HordeCoordinator with its own registry
          %{
            id: Arbor.Core.CoordinationSupervisor,
            start: {Arbor.Core.HordeCoordinator, :start_coordination, []},
            type: :supervisor
          }
        ]
      else
        []
      end

    children = distributed_children ++ base_children

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

  @impl true
  defp handle_telemetry_event(event_name, measurements, metadata, _config) do
    Logger.debug("Telemetry event",
      event: event_name,
      measurements: measurements,
      metadata: metadata
    )
  end

  # Implement required callbacks from Arbor.Contracts.Core.Application

  @impl true
  def process(input) do
    # This is the main application module, not a processing module
    # Return a generic response
    {:ok, input}
  end

  @impl true
  def configure(_options) do
    # Configuration is handled through the Application environment
    # This callback can be used for runtime configuration updates
    :ok
  end
end
