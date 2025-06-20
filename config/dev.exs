import Config

# Configure development database
config :arbor_persistence, Arbor.Persistence.Repo,
  username: System.get_env("POSTGRES_USER", "arbor_dev"),
  password: System.get_env("POSTGRES_PASSWORD", "arbor_dev"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: System.get_env("POSTGRES_DB", "arbor_dev"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
  # Enable SQL query logging in dev
  log: :debug,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Configure event journal for development
config :arbor_persistence, Arbor.Persistence.EventJournal,
  batch_size: 10,
  flush_interval: 1000,
  data_dir: "./data/journals"

# Configure security database
config :arbor_security, Arbor.Security.Repo,
  username: System.get_env("POSTGRES_USER", "arbor_dev"),
  password: System.get_env("POSTGRES_PASSWORD", "arbor_dev"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: System.get_env("POSTGRES_DB", "arbor_security_dev"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
  # Enable SQL query logging in dev
  log: :debug,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
