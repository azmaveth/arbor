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
