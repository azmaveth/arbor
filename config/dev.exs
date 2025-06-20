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

# Configure libcluster for automatic node discovery
# Using Gossip strategy for local development
config :libcluster,
  topologies: [
    arbor_dev: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_addr: "255.255.255.255",
        multicast_ttl: 1,
        secret: "arbor_development_cluster"
      ],
      # Connect to nodes with the same prefix
      connect: {:net_kernel, :connect_node, []},
      disconnect: {:erlang, :disconnect_node, []},
      child_spec: [restart: :transient]
    ]
  ]

# Configure distributed Erlang (only for releases)
if System.get_env("RELEASE_MODE") do
  config :kernel,
    inet_dist_listen_min: 9100,
    inet_dist_listen_max: 9200
end
