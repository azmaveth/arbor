import Config

# Configure test database
config :arbor_persistence, Arbor.Persistence.Repo,
  username: System.get_env("POSTGRES_USER", "arbor_test"),
  password: System.get_env("POSTGRES_PASSWORD", "arbor_test"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: System.get_env("POSTGRES_DB", "arbor_test"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
  # Disable query logging in tests for cleaner output
  log: false

# Configure logger for tests
config :logger, level: :warning

# Configure event journal for testing
config :arbor_persistence, Arbor.Persistence.EventJournal,
  batch_size: 3,
  flush_interval: 100,
  data_dir: System.tmp_dir!() <> "/arbor_test_journals"
