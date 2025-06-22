ExUnit.start()

# Configure test environment
Application.put_env(:arbor_cli, :gateway_endpoint, "http://localhost:4000")
Application.put_env(:arbor_cli, :output_format, :table)
Application.put_env(:arbor_cli, :timeout, 30_000)
Application.put_env(:arbor_cli, :verbose, false)
Application.put_env(:arbor_cli, :telemetry_enabled, false)