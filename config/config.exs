# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    # Request tracking
    :request_id,
    :trace_id,

    # Core identifiers
    :session_id,
    :execution_id,
    :capability_id,
    :agent_id,
    :message_id,

    # Context data
    :command,
    :reason,
    :resource_uri,
    :created_by,
    :from,
    :subscriber,

    # Metrics
    :idle_seconds,
    :timeout,
    :timeout_ms,
    :uptime_seconds,
    :duration_seconds,
    :events_count,

    # Generic fields
    :opts,
    :metadata,
    :message,
    :event,
    :measurements,
    :ref,
    :result,

    # Process and system info
    :pid,
    :node,
    :existing_pid,
    :new_pid,
    :current_pid,

    # HTTP/Request fields
    :method,
    :path,
    :body_size,
    :endpoint,
    :pool_size,

    # Error tracking
    :error,
    :errors,
    :exception,
    :stacktrace,
    :validation_enabled,

    # Performance metrics
    :duration_ms,
    :delay_ms,
    :retries_left,

    # Code analysis
    :args,
    :args_count,
    :working_dir,
    :files_analyzed,
    :language,
    :function,
    :schema,
    :type,
    :subcommand,
    :command_type,

    # Agent behavior
    :retries,
    :initial_delay,
    :supervisor_impl,
    :registry_members,
    :supervisor_members,
    :current_node,

    # Supervisor/Registry
    :supervisor_status,
    :registry_status,
    :horde_supervisor_status,
    :restart_strategy,

    # Agent reconciliation
    :specs,
    :running,
    :missing,
    :orphaned,
    :restarted,
    :cleaned,
    :remaining_agents,
    :recovered,
    :checkpoint_count,
    :children,
    :count,
    :counter,
    :data,
    :options,
    :restart_errors,
    :cleanup_errors,

    # Additional metadata keys used in the codebase
    :spec_key,
    :status,

    # Test-specific metadata
    :test,
    :test_module,
    :test_pid,
    :test_timestamp
  ]

# Configure Arbor Persistence Ecto Repository
config :arbor_persistence, Arbor.Persistence.Repo,
  username: System.get_env("POSTGRES_USER", "arbor_dev"),
  password: System.get_env("POSTGRES_PASSWORD", "arbor_dev"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: System.get_env("POSTGRES_DB", "arbor_dev"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
  # Enable SQL query logging in dev
  log: if(Mix.env() == :dev, do: :debug, else: false),
  # Timeout configuration for long migrations
  migration_lock: :pg_advisory_lock,
  migration_primary_key: [name: :id, type: :binary_id]

# Configure Ecto repositories
config :arbor_persistence, ecto_repos: [Arbor.Persistence.Repo]

# Configure Arbor Core distributed system timing parameters
# These defaults work well for production but can be overridden per environment
config :arbor_core,
  # Agent registration retry configuration
  agent_retry: [
    # Number of retry attempts for agent registration
    retries: 3,
    # Initial delay in milliseconds, doubles with each retry
    initial_delay: 250
  ],
  # Horde CRDT synchronization configuration
  horde_timing: [
    # CRDT sync interval in milliseconds (100ms minimum recommended)
    sync_interval: 100
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
