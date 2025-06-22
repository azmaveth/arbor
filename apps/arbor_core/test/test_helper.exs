# Ensure all required applications are started
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:telemetry_poller)
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

# Start a mock session registry for tests
{:ok, _} = Registry.start_link(keys: :unique, name: Arbor.Core.MockSessionRegistry)

ExUnit.start()
