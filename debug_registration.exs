#!/usr/bin/env elixir

# Simple debug script to test agent registration flow
Mix.install([
  {:horde, "~> 0.9.0"}
])

defmodule DebugTestAgent do
  use GenServer
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    agent_id = Keyword.get(args, :agent_id)
    
    state = %{
      agent_id: agent_id,
      started_at: System.system_time(:millisecond)
    }
    
    Logger.info("DebugTestAgent #{agent_id} starting init")
    
    # Try to register with manual call
    try do
      case GenServer.whereis(Arbor.Core.HordeSupervisor) do
        nil -> 
          Logger.error("HordeSupervisor not found!")
        pid -> 
          Logger.info("HordeSupervisor found at #{inspect(pid)}")
          
          result = GenServer.call(pid, {:register_agent, self(), agent_id, %{type: :debug_test}})
          Logger.info("Registration result: #{inspect(result)}")
      end
    rescue
      error ->
        Logger.error("Registration error: #{inspect(error)}")
    end
    
    {:ok, state}
  end
end

# Minimal registry setup
{:ok, registry} = Horde.Registry.start_link(
  name: Arbor.Core.HordeAgentRegistry,
  keys: :unique,
  members: :auto
)

# Start a simple GenServer that mimics HordeSupervisor registration handling
defmodule SimpleRegistrationHandler do
  use GenServer
  
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: Arbor.Core.HordeSupervisor)
  end
  
  def init(state) do
    IO.puts("SimpleRegistrationHandler started")
    {:ok, state}
  end
  
  def handle_call({:register_agent, pid, agent_id, metadata}, _from, state) do
    IO.puts("Received registration request for #{agent_id} from #{inspect(pid)}")
    
    result = Horde.Registry.register(Arbor.Core.HordeAgentRegistry, {:agent, agent_id}, metadata)
    IO.puts("Registry result: #{inspect(result)}")
    
    {:reply, {:ok, pid}, state}
  end
end

{:ok, handler} = SimpleRegistrationHandler.start_link([])

# Test the registration
{:ok, agent_pid} = DebugTestAgent.start_link([agent_id: "test-debug-123"])

# Check if registered
:timer.sleep(100)
case Horde.Registry.lookup(Arbor.Core.HordeAgentRegistry, {:agent, "test-debug-123"}) do
  [] -> IO.puts("❌ Agent not registered")
  [{^agent_pid, metadata}] -> IO.puts("✅ Agent registered with metadata: #{inspect(metadata)}")
  other -> IO.puts("❓ Unexpected registry result: #{inspect(other)}")
end