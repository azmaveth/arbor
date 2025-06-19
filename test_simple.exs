#!/usr/bin/env elixir

# Simple test to verify compilation and module loading
Mix.install([])

IO.puts("🧪 Testing Arbor Core Module Loading\n")

# Test 1: Check if we can load the modules
modules_to_test = [
  Arbor.Agent,
  Arbor.Types,
  Arbor.Contracts.Core.Message,
  Arbor.Contracts.Core.Capability,
  Arbor.Core.Gateway,
  Arbor.Core.Sessions.Manager,
  Arbor.Core.Sessions.Session,
  Arbor.Core.Application
]

IO.puts("1️⃣  Testing Module Loading...")
Enum.each(modules_to_test, fn module ->
  try do
    Code.ensure_loaded!(module)
    IO.puts("   ✅ #{module} loaded successfully")
  rescue
    _ ->
      IO.puts("   ❌ #{module} failed to load")
  end
end)

# Test 2: Check basic type generation
IO.puts("\n2️⃣  Testing Type Generation...")
try do
  agent_id = Arbor.Types.generate_agent_id()
  session_id = Arbor.Types.generate_session_id()
  capability_id = Arbor.Types.generate_capability_id()
  
  IO.puts("   ✅ Agent ID: #{agent_id}")
  IO.puts("   ✅ Session ID: #{session_id}")
  IO.puts("   ✅ Capability ID: #{capability_id}")
rescue
  e ->
    IO.puts("   ❌ Type generation failed: #{inspect(e)}")
end

# Test 3: Test URI validation
IO.puts("\n3️⃣  Testing URI Validation...")
test_uris = [
  {"arbor://agent/agent_abc123", :agent_uri},
  {"arbor://fs/read/home/user", :resource_uri},
  {"invalid-uri", :invalid}
]

Enum.each(test_uris, fn {uri, expected} ->
  case expected do
    :agent_uri ->
      result = Arbor.Types.valid_agent_uri?(uri)
      IO.puts("   #{if result, do: "✅", else: "❌"} Agent URI '#{uri}': #{result}")
    
    :resource_uri ->
      result = Arbor.Types.valid_resource_uri?(uri)
      IO.puts("   #{if result, do: "✅", else: "❌"} Resource URI '#{uri}': #{result}")
    
    :invalid ->
      agent_result = Arbor.Types.valid_agent_uri?(uri)
      resource_result = Arbor.Types.valid_resource_uri?(uri)
      expected_false = not agent_result and not resource_result
      IO.puts("   #{if expected_false, do: "✅", else: "❌"} Invalid URI '#{uri}' correctly rejected: #{expected_false}")
  end
end)

# Test 4: Test struct creation
IO.puts("\n4️⃣  Testing Struct Creation...")

# Test message creation
try do
  {:ok, message} = Arbor.Contracts.Core.Message.new(
    to: "arbor://agent/agent_abc123",
    from: "arbor://agent/agent_def456",
    payload: %{type: :test, data: "hello"}
  )
  IO.puts("   ✅ Message created: ID=#{message.id}")
rescue
  e ->
    IO.puts("   ❌ Message creation failed: #{inspect(e)}")
end

# Test capability creation
try do
  {:ok, capability} = Arbor.Contracts.Core.Capability.new(
    resource_uri: "arbor://fs/read/home/user",
    principal_id: "agent_abc123"
  )
  IO.puts("   ✅ Capability created: ID=#{capability.id}")
rescue
  e ->
    IO.puts("   ❌ Capability creation failed: #{inspect(e)}")
end

IO.puts("\n✅ Basic module tests completed!\n")

IO.puts("🚀 What you can test manually:")
IO.puts("   1. Start IEx: 'iex -S mix'")
IO.puts("   2. Create a session: {:ok, session_id} = Arbor.Core.Gateway.create_session()")
IO.puts("   3. Discover capabilities: Arbor.Core.Gateway.discover_capabilities(session_id)")
IO.puts("   4. Execute commands: Arbor.Core.Gateway.execute(session_id, \"analyze_code\", %{path: \"/test\"})")
IO.puts("   5. Check stats: Arbor.Core.Gateway.get_stats()")
IO.puts("   6. Subscribe to events: Phoenix.PubSub.subscribe(Arbor.PubSub, \"sessions\")")
IO.puts("   7. End session: Arbor.Core.Gateway.end_session(session_id)")