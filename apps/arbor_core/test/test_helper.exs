# Ensure all required applications are started
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:telemetry_poller)
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

ExUnit.start()
