#!/usr/bin/env elixir

# Manual Testing Script for Arbor Gateway Pattern Implementation
# Run with: elixir test_gateway.exs

# Start the application
Application.put_env(:arbor_core, :start_permanent, false)
Application.ensure_all_started(:arbor_core)

defmodule ArborTester do
  @moduledoc """
  Manual testing utilities for the Arbor Gateway implementation.
  """

  require Logger

  def run_tests do
    IO.puts("\n🧪 Testing Arbor Gateway Pattern Implementation\n")
    
    # Test 1: Basic Gateway functionality
    test_gateway_startup()
    
    # Test 2: Session management
    test_session_lifecycle()
    
    # Test 3: Capability discovery
    test_capability_discovery()
    
    # Test 4: Event subscription
    test_event_subscription()
    
    # Test 5: Asynchronous command execution
    test_async_execution()
    
    # Test 6: Gateway statistics
    test_gateway_stats()
    
    IO.puts("\n✅ All tests completed!\n")
  end

  defp test_gateway_startup do
    IO.puts("1️⃣  Testing Gateway Startup...")
    
    case Process.whereis(Arbor.Core.Gateway) do
      pid when is_pid(pid) ->
        IO.puts("   ✅ Gateway process is running (PID: #{inspect(pid)})")
      nil ->
        IO.puts("   ❌ Gateway process not found")
    end
    
    case Process.whereis(Arbor.Core.Sessions.Manager) do
      pid when is_pid(pid) ->
        IO.puts("   ✅ Session Manager is running (PID: #{inspect(pid)})")
      nil ->
        IO.puts("   ❌ Session Manager process not found")
    end
    
    case Process.whereis(Arbor.PubSub) do
      pid when is_pid(pid) ->
        IO.puts("   ✅ PubSub is running (PID: #{inspect(pid)})")
      nil ->
        IO.puts("   ❌ PubSub process not found")
    end
    
    IO.puts("")
  end

  defp test_session_lifecycle do
    IO.puts("2️⃣  Testing Session Lifecycle...")
    
    # Create a session
    case Arbor.Core.Gateway.create_session(metadata: %{test: "manual_test", client_type: :cli}) do
      {:ok, session_id} ->
        IO.puts("   ✅ Session created: #{session_id}")
        
        # Verify session exists
        case Arbor.Core.Sessions.Manager.get_session(session_id) do
          {:ok, pid, metadata} ->
            IO.puts("   ✅ Session found: PID=#{inspect(pid)}, Metadata=#{inspect(metadata)}")
          {:error, reason} ->
            IO.puts("   ❌ Session not found: #{reason}")
        end
        
        # List sessions
        sessions = Arbor.Core.Sessions.Manager.list_sessions()
        IO.puts("   ✅ Active sessions: #{length(sessions)}")
        
        # Get session state
        case Arbor.Core.Sessions.Manager.get_session(session_id) do
          {:ok, session_pid, _} ->
            case Arbor.Core.Sessions.Session.get_state(session_pid) do
              {:ok, state} ->
                IO.puts("   ✅ Session state retrieved: uptime=#{state.uptime_seconds}s")
              error ->
                IO.puts("   ❌ Failed to get session state: #{inspect(error)}")
            end
          _ ->
            IO.puts("   ❌ Session not found for state check")
        end
        
        # End session
        case Arbor.Core.Gateway.end_session(session_id) do
          :ok ->
            IO.puts("   ✅ Session ended successfully")
          error ->
            IO.puts("   ❌ Failed to end session: #{inspect(error)}")
        end
        
      {:error, reason} ->
        IO.puts("   ❌ Failed to create session: #{reason}")
    end
    
    IO.puts("")
  end

  defp test_capability_discovery do
    IO.puts("3️⃣  Testing Capability Discovery...")
    
    # Create a session first
    case Arbor.Core.Gateway.create_session() do
      {:ok, session_id} ->
        case Arbor.Core.Gateway.discover_capabilities(session_id) do
          {:ok, capabilities} ->
            IO.puts("   ✅ Discovered #{length(capabilities)} capabilities:")
            Enum.each(capabilities, fn cap ->
              IO.puts("      - #{cap.name}: #{cap.description}")
            end)
          {:error, reason} ->
            IO.puts("   ❌ Capability discovery failed: #{reason}")
        end
        
        # Clean up
        Arbor.Core.Gateway.end_session(session_id)
      
      {:error, reason} ->
        IO.puts("   ❌ Failed to create session for capability test: #{reason}")
    end
    
    IO.puts("")
  end

  defp test_event_subscription do
    IO.puts("4️⃣  Testing Event Subscription...")
    
    # Subscribe to session events
    Phoenix.PubSub.subscribe(Arbor.PubSub, "sessions")
    IO.puts("   ✅ Subscribed to session events")
    
    # Create a session to trigger events
    case Arbor.Core.Gateway.create_session(metadata: %{test: "event_test"}) do
      {:ok, session_id} ->
        IO.puts("   ✅ Session created for event testing: #{session_id}")
        
        # Wait a bit for events
        receive do
          {:session_created, ^session_id, metadata} ->
            IO.puts("   ✅ Received session_created event: #{inspect(metadata)}")
        after 1000 ->
          IO.puts("   ⚠️  No session_created event received (might be expected)")
        end
        
        # End session
        Arbor.Core.Gateway.end_session(session_id)
        
        # Wait for session ended event
        receive do
          {:session_ended, ^session_id, reason} ->
            IO.puts("   ✅ Received session_ended event: #{reason}")
        after 1000 ->
            IO.puts("   ⚠️  No session_ended event received (might be expected)")
        end
        
      {:error, reason} ->
        IO.puts("   ❌ Failed to create session for event test: #{reason}")
    end
    
    IO.puts("")
  end

  defp test_async_execution do
    IO.puts("5️⃣  Testing Asynchronous Execution...")
    
    case Arbor.Core.Gateway.create_session() do
      {:ok, session_id} ->
        # Subscribe to execution events
        Phoenix.PubSub.subscribe(Arbor.PubSub, "session:#{session_id}")
        IO.puts("   ✅ Subscribed to execution events for session #{session_id}")
        
        # Execute a command
        case Arbor.Core.Gateway.execute(session_id, "analyze_code", %{path: "/test/path"}) do
          {:async, execution_id} ->
            IO.puts("   ✅ Command started asynchronously: #{execution_id}")
            
            # Subscribe to specific execution
            Arbor.Core.Gateway.subscribe_execution(execution_id)
            
            # Wait for execution events
            wait_for_execution_events(execution_id, 3)
            
          {:error, reason} ->
            IO.puts("   ❌ Command execution failed: #{reason}")
        end
        
        # Clean up
        Arbor.Core.Gateway.end_session(session_id)
        
      {:error, reason} ->
        IO.puts("   ❌ Failed to create session for execution test: #{reason}")
    end
    
    IO.puts("")
  end

  defp test_gateway_stats do
    IO.puts("6️⃣  Testing Gateway Statistics...")
    
    case Arbor.Core.Gateway.get_stats() do
      {:ok, stats} ->
        IO.puts("   ✅ Gateway statistics:")
        IO.puts("      - Sessions created: #{stats.sessions_created}")
        IO.puts("      - Commands executed: #{stats.commands_executed}")
        IO.puts("      - Active sessions: #{stats.active_sessions}")
        IO.puts("      - Active executions: #{stats.active_executions}")
        IO.puts("      - Uptime: #{stats.uptime_seconds} seconds")
      
      {:error, reason} ->
        IO.puts("   ❌ Failed to get gateway stats: #{reason}")
    end
    
    case Arbor.Core.Sessions.Manager.get_stats() do
      {:ok, stats} ->
        IO.puts("   ✅ Session Manager statistics:")
        IO.puts("      - Total created: #{stats.total_created}")
        IO.puts("      - Total ended: #{stats.total_ended}")
        IO.puts("      - Currently active: #{stats.active_sessions}")
        IO.puts("      - Uptime: #{stats.uptime_seconds} seconds")
      
      {:error, reason} ->
        IO.puts("   ❌ Failed to get session manager stats: #{reason}")
    end
    
    IO.puts("")
  end

  defp wait_for_execution_events(execution_id, count) when count > 0 do
    receive do
      {:execution_event, event} ->
        if event.execution_id == execution_id do
          IO.puts("   ✅ Execution event: #{event.status} - #{event.message}")
          if event.status == :completed do
            IO.puts("      Result: #{inspect(event.result)}")
          end
          wait_for_execution_events(execution_id, count - 1)
        else
          wait_for_execution_events(execution_id, count)
        end
    after 2000 ->
      IO.puts("   ⚠️  Timeout waiting for execution events")
    end
  end

  defp wait_for_execution_events(_execution_id, 0) do
    IO.puts("   ✅ Received all expected execution events")
  end
end

# Run the tests
ArborTester.run_tests()

# Keep the application running for a moment
Process.sleep(1000)