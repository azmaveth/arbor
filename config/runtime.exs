import Config

# Runtime configuration for Arbor system
# This file is executed when the release starts

# Configure logging based on environment
if config_env() == :prod do
  # Configure structured logging for production
  config :logger,
    level: String.to_existing_atom(System.get_env("LOG_LEVEL", "info")),
    backends: [:console],
    compile_time_purge_matching: [
      [level_lower_than: :info]
    ]

  config :logger, :console,
    format: "$time $metadata[$level] $message\n",
    metadata: [:request_id, :session_id, :execution_id]
end

# Database configuration
if database_url = System.get_env("DATABASE_URL") do
  config :arbor_persistence, Arbor.Persistence.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    socket_options: [:inet6]
end

# Redis configuration for distributed state
if redis_url = System.get_env("REDIS_URL") do
  uri = URI.parse(redis_url)

  config :redix,
    host: uri.host,
    port: uri.port,
    password: uri.userinfo && List.last(String.split(uri.userinfo, ":")),
    database: String.to_integer(System.get_env("REDIS_DB", "0"))
end

# Clustering configuration
if node_name = System.get_env("NODE_NAME") do
  config :arbor_core,
    clustering: [
      node_name: String.to_atom(node_name),
      cookie: String.to_atom(System.get_env("ERLANG_COOKIE", "arbor_cluster_cookie")),
      topology: [
        arbor: [
          strategy: Cluster.Strategy.Epmd,
          config: [
            hosts:
              System.get_env("CLUSTER_HOSTS", "")
              |> String.split(",")
              |> Enum.reject(&(&1 == ""))
              |> Enum.map(&String.to_atom/1)
          ]
        ]
      ]
    ]
end

# Telemetry and observability configuration
config :arbor_core,
  telemetry: [
    metrics_port: String.to_integer(System.get_env("METRICS_PORT", "9464")),
    enable_prometheus: System.get_env("ENABLE_PROMETHEUS", "true") == "true",
    enable_jaeger: System.get_env("ENABLE_JAEGER", "true") == "true",
    jaeger_endpoint: System.get_env("JAEGER_ENDPOINT", "http://jaeger:14268/api/traces")
  ]

# Gateway configuration
config :arbor_core,
  gateway: [
    max_sessions: String.to_integer(System.get_env("MAX_SESSIONS", "1000")),
    session_timeout:
      String.to_integer(System.get_env("SESSION_TIMEOUT_HOURS", "4")) * 60 * 60 * 1000,
    command_timeout:
      String.to_integer(System.get_env("COMMAND_TIMEOUT_MINUTES", "10")) * 60 * 1000,
    rate_limit: [
      max_requests: String.to_integer(System.get_env("RATE_LIMIT_REQUESTS", "100")),
      window_seconds: String.to_integer(System.get_env("RATE_LIMIT_WINDOW", "60"))
    ]
  ]

# Security configuration
config :arbor_security,
  capability_signing_key:
    System.get_env("CAPABILITY_SIGNING_KEY") ||
      "dev_default_capability_signing_key_unsafe",
  encryption_key:
    System.get_env("ENCRYPTION_KEY") ||
      "dev_default_encryption_key_unsafe_32b",
  enable_audit_logging: System.get_env("ENABLE_AUDIT_LOGGING", "true") == "true"

# Application-specific environment variables
if port = System.get_env("PORT") do
  config :arbor_core, :port, String.to_integer(port)
end

if beam_port = System.get_env("BEAM_PORT") do
  config :arbor_core, :beam_port, String.to_integer(beam_port)
end
