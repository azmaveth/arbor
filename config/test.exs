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

# Configure security database for testing
config :arbor_security, Arbor.Security.Repo,
  username: System.get_env("POSTGRES_USER", "arbor_test"),
  password: System.get_env("POSTGRES_PASSWORD", "arbor_test"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: System.get_env("POSTGRES_DB", "arbor_security_test"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "10")),
  # Disable query logging in tests for cleaner output
  log: false

# Tell security application to use mock databases for most tests
config :arbor_security, :use_mock_db, true

# Configure security app for test environment
config :arbor_security, :env, :test

# Configure libcluster for test environment
# Using Epmd strategy for predictable test clustering
config :libcluster,
  topologies: [
    arbor_test: [
      strategy: Cluster.Strategy.Epmd,
      config: [
        hosts: [:"arbor1@127.0.0.1", :"arbor2@127.0.0.1", :"arbor3@127.0.0.1"]
      ],
      child_spec: [restart: :transient]
    ]
  ]

# For most tests, we'll use the mock implementations
config :arbor_core,
  env: :test,
  registry_impl: :mock,
  supervisor_impl: :mock,
  coordinator_impl: :mock
