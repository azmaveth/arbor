
# Test to isolate the issue
alias Arbor.Core.HordeSupervisor

# Test the lookup function directly
IO.puts("\n=== Testing Registry Lookup Functions ===")

# Try a direct registry operation
test_key = {:agent_spec, "direct_test"}
test_value = %{test: true, timestamp: System.system_time()}

# Register directly
register_result = Horde.Registry.register(Arbor.Core.HordeAgentRegistry, test_key, test_value)
IO.inspect(register_result, label: "direct register result")

# Lookup with Horde.Registry.lookup
direct_lookup = Horde.Registry.lookup(Arbor.Core.HordeAgentRegistry, test_key)
IO.inspect(direct_lookup, label: "direct lookup result")

# Lookup with HordeSupervisor.lookup_agent_spec
hs_lookup = HordeSupervisor.lookup_agent_spec("direct_test")
IO.inspect(hs_lookup, label: "HordeSupervisor lookup result")

# Check if there is a difference between the two lookup methods
IO.puts("\n=== Registry Select Method Test ===")

# This is what lookup_agent_spec uses internally
pattern = {test_key, :"$1", :"$2"}
guard = []
body = [:"$2"]
select_result = Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [{pattern, guard, body}])
IO.inspect(select_result, label: "select result")

# Cleanup
Horde.Registry.unregister(Arbor.Core.HordeAgentRegistry, test_key)

