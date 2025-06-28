
# Debug the start_agent flow
alias Arbor.Core.HordeSupervisor
alias Arbor.Agents.CodeAnalyzer

# Create agent spec
agent_spec = %{
  id: "debug_agent_001",
  module: CodeAnalyzer,
  args: [agent_id: "debug_agent_001", working_dir: "/tmp"],
  restart: :permanent
}

IO.puts("\n=== Starting agent with debug tracing ===")

# Enable debug logging temporarily
Logger.configure(level: :debug)

# Start the agent and capture the result
result = HordeSupervisor.start_agent(agent_spec)
IO.inspect(result, label: "start_agent result")

# Check if spec was registered
spec_lookup = HordeSupervisor.lookup_agent_spec("debug_agent_001")
IO.inspect(spec_lookup, label: "spec lookup after start_agent")

# Check all registrations for our agent
all_registrations = Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [{{:_, :_, :_}, [], [:"$_"]}])
|> Enum.filter(fn {key, _pid, _value} -> 
  case key do
    {:agent_spec, id} when id == "debug_agent_001" -> true
    {:agent, id} when id == "debug_agent_001" -> true
    _ -> false
  end
end)
IO.inspect(all_registrations, label: "all registrations for debug_agent_001")

