#!/usr/bin/env elixir

# Simple CLI Integration Test
# Tests the HTTP API integration between CLI and Core

Mix.install([
  {:httpoison, "~> 2.0"},
  {:jason, "~> 1.4"}
])

defmodule CLIIntegrationTest do
  def run do
    IO.puts("🔨 CLI Integration Test")
    IO.puts("========================")
    
    # Test 1: HTTP API server availability
    IO.puts("\n1. Testing HTTP API server availability...")
    test_server_availability()
    
    # Test 2: Session creation via HTTP
    IO.puts("\n2. Testing session creation via HTTP...")
    test_session_creation()
    
    # Test 3: Command execution via HTTP
    IO.puts("\n3. Testing command execution via HTTP...")
    test_command_execution()
    
    IO.puts("\n✅ CLI Integration Test completed!")
  end
  
  defp test_server_availability do
    case HTTPoison.get("http://localhost:4000/sessions", [], timeout: 1000) do
      {:ok, %{status_code: status}} when status in 200..299 ->
        IO.puts("   ✅ HTTP server is running and responsive")
        
      {:ok, %{status_code: status}} ->
        IO.puts("   ⚠️  HTTP server responded with status #{status}")
        
      {:error, %HTTPoison.Error{reason: :econnrefused}} ->
        IO.puts("   ❌ HTTP server not running (connection refused)")
        IO.puts("   💡 Start the server with: ./scripts/dev.sh")
        
      {:error, %HTTPoison.Error{reason: reason}} ->
        IO.puts("   ❌ HTTP request failed: #{inspect(reason)}")
    end
  end
  
  defp test_session_creation do
    body = %{
      metadata: %{user: "test_user", client: "cli_test"},
      timeout: 300_000
    }
    
    case HTTPoison.post(
      "http://localhost:4000/sessions",
      Jason.encode!(body),
      [{"content-type", "application/json"}],
      timeout: 5000
    ) do
      {:ok, %{status_code: 201, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, session_info} ->
            IO.puts("   ✅ Session created successfully")
            IO.puts("   📋 Session ID: #{session_info["session_id"] || session_info[:session_id]}")
            session_info
            
          {:error, _} ->
            IO.puts("   ⚠️  Session created but response was not valid JSON")
            %{}
        end
        
      {:ok, %{status_code: status, body: body}} ->
        IO.puts("   ❌ Session creation failed with status #{status}")
        IO.puts("   📄 Response: #{body}")
        %{}
        
      {:error, %HTTPoison.Error{reason: :econnrefused}} ->
        IO.puts("   ❌ Cannot connect to server - ensure it's running")
        %{}
        
      {:error, error} ->
        IO.puts("   ❌ HTTP request failed: #{inspect(error)}")
        %{}
    end
  end
  
  defp test_command_execution do
    # Try to execute a simple command
    command = %{
      type: "test_command",
      payload: %{message: "Hello from CLI integration test"}
    }
    
    case HTTPoison.post(
      "http://localhost:4000/commands",
      Jason.encode!(command),
      [
        {"content-type", "application/json"},
        {"x-session-id", "test_session_123"}
      ],
      timeout: 5000
    ) do
      {:ok, %{status_code: 202, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, execution_info} ->
            IO.puts("   ✅ Command submitted successfully")
            IO.puts("   🏃 Execution ID: #{execution_info["execution_id"] || execution_info[:execution_id]}")
            
          {:error, _} ->
            IO.puts("   ⚠️  Command submitted but response was not valid JSON")
        end
        
      {:ok, %{status_code: 400, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"error" => error}} ->
            IO.puts("   ⚠️  Command rejected: #{error}")
          _ ->
            IO.puts("   ⚠️  Command rejected with status 400")
        end
        
      {:ok, %{status_code: 404}} ->
        IO.puts("   ⚠️  Session not found (expected for test session)")
        
      {:ok, %{status_code: status, body: body}} ->
        IO.puts("   ❌ Command execution failed with status #{status}")
        IO.puts("   📄 Response: #{body}")
        
      {:error, %HTTPoison.Error{reason: :econnrefused}} ->
        IO.puts("   ❌ Cannot connect to server - ensure it's running")
        
      {:error, error} ->
        IO.puts("   ❌ HTTP request failed: #{inspect(error)}")
    end
  end
end

CLIIntegrationTest.run()