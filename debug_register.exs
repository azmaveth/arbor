
# Test register_agent_spec function directly
spec_metadata = %{
  module: Arbor.Agents.CodeAnalyzer,
  args: [agent_id: "test_debug", working_dir: "/tmp"],
  restart: :permanent,
  metadata: %{type: :code_analyzer}
}

# Try to call the private function via module evaluation
result = :erlang.apply(Arbor.Core.HordeSupervisor, :register_agent_spec, ["test_debug", spec_metadata])
IO.inspect(result, label: "register_agent_spec result")

# Check if it was actually registered
lookup_result = Horde.Registry.lookup(Arbor.Core.HordeAgentRegistry, {:agent_spec, "test_debug"})
IO.inspect(lookup_result, label: "lookup result")

