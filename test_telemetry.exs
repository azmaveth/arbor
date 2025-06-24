#!/usr/bin/env elixir

# Load and test the telemetry generator
Code.eval_file("../../tmp/scripts/generate_telemetry.exs")

# Test session creation first
session_params = %{
  user_id: "test_user",
  purpose: "Telemetry test session",
  timeout: 3_600_000,
  context: %{test: true}
}
{:ok, session_struct} = Arbor.Core.Sessions.Manager.create_session(session_params, Arbor.Core.Sessions.Manager)
session_id = session_struct.id
IO.puts("✅ Created test session: #{session_id}")

# Test gateway session creation
{:ok, gateway_session_id} = Arbor.Core.Gateway.create_session(
  metadata: %{test: true, via: :gateway}
)
IO.puts("✅ Created gateway session: #{gateway_session_id}")

# Test simple burst
IO.puts("🚀 Starting telemetry burst test...")
TelemetryGenerator.generate_burst_activity()