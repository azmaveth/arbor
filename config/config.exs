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
    :result
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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
