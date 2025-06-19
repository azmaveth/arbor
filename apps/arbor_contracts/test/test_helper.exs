# Start dependencies that might be needed
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

ExUnit.start()
