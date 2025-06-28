#!/usr/bin/env elixir

# Test script for Getting Started guide commands
IO.puts("\n🧪 Testing Getting Started Guide Commands\n")

# Helper function to test a command
defmodule TestHelper do
  def test_command(description, fun) do
    IO.puts("▶️  Testing: #{description}")
    
    try do
      result = fun.()
      IO.puts("✅ Success: #{inspect(result, pretty: true, limit: :infinity)}")
      {:ok, result}
    rescue
      e ->
        IO.puts("❌ Error: #{inspect(e)}")
        {:error, e}
    end
    
    IO.puts("")
  end
end

# Test 1: Create a Session
IO.puts("=== Test 1: Create a Session ===")
session_result = TestHelper.test_command("Creating a session", fn ->
  {:ok, session} = Arbor.Core.Sessions.Manager.create_session(%{
    user_id: "test_user",
    metadata: %{purpose: "testing"}
  })
  session
end)

# Extract session_id if successful
session_id = case session_result do
  {:ok, session} -> session.id
  _ -> nil
end

if session_id do
  IO.puts("📝 Session ID: #{session_id}\n")
  
  # Test 2: Spawn an Agent
  IO.puts("=== Test 2: Spawn an Agent ===")
  spawn_result = TestHelper.test_command("Spawning a code analyzer agent", fn ->
    {:ok, execution_id} = Arbor.Core.Gateway.execute_command(
      %{
        type: :spawn_agent,
        params: %{
          type: :code_analyzer,
          working_dir: "/tmp"
        }
      },
      %{session_id: session_id},
      %{}
    )
    execution_id
  end)
  
  # Test 3: Query Agents
  IO.puts("=== Test 3: Query Agents ===")
  query_result = TestHelper.test_command("Querying agents", fn ->
    {:ok, execution_id} = Arbor.Core.Gateway.execute_command(
      %{
        type: :query_agents,
        params: %{}
      },
      %{session_id: session_id},
      %{}
    )
    execution_id
  end)
  
  # Wait a bit for agent to spawn
  IO.puts("⏳ Waiting 2 seconds for agent to spawn...")
  Process.sleep(2000)
  
  # Test 4: Check Agent Status
  IO.puts("\n=== Test 4: Check Agent Status ===")
  TestHelper.test_command("Listing agents via HordeSupervisor", fn ->
    {:ok, agents} = Arbor.Core.HordeSupervisor.list_agents()
    agents
  end)
  
  # If we have agents, test command execution
  case Arbor.Core.HordeSupervisor.list_agents() do
    {:ok, [agent | _]} ->
      agent_id = agent.id
      IO.puts("📝 Found agent ID: #{agent_id}\n")
      
      # Test 5: Execute Agent Command
      IO.puts("=== Test 5: Execute Agent Command ===")
      TestHelper.test_command("Executing agent command", fn ->
        {:ok, execution_id} = Arbor.Core.Gateway.execute_command(
          %{
            type: :execute_agent_command,
            params: %{
              agent_id: agent_id,
              command: "analyze",
              args: ["lib/arbor/core/gateway.ex"]
            }
          },
          %{session_id: session_id},
          %{}
        )
        execution_id
      end)
      
      # Test 6: Get Agent Info
      IO.puts("=== Test 6: Get Agent Info ===")
      TestHelper.test_command("Getting agent info", fn ->
        {:ok, agent_info} = Arbor.Core.HordeSupervisor.get_agent_info(agent_id)
        agent_info
      end)
      
    _ ->
      IO.puts("⚠️  No agents found to test command execution")
  end
  
  # Test 7: Monitor Commands
  IO.puts("\n=== Test 7: Monitoring Commands ===")
  
  TestHelper.test_command("Cluster status", fn ->
    Arbor.Core.ClusterManager.cluster_status()
  end)
  
  TestHelper.test_command("Registry status", fn ->
    Arbor.Core.HordeRegistry.get_registry_status()
  end)
  
  # Test 8: Telemetry Events
  IO.puts("=== Test 8: Telemetry Events ===")
  TestHelper.test_command("Attaching telemetry handler", fn ->
    :telemetry.attach(
      "print-agent-events",
      [:arbor, :agent, :started],
      fn event, measurements, metadata, _config ->
        IO.inspect({event, measurements, metadata}, label: "Telemetry Event")
      end,
      nil
    )
  end)
  
else
  IO.puts("❌ Failed to create session, skipping remaining tests")
end

IO.puts("\n✅ Testing completed!")