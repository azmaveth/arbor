
# Check current system state
IO.puts("\n=== System Health Check ===")

# Check if modules are loaded
modules_to_check = [
  Arbor.Core.HordeSupervisor,
  Arbor.Agents.CodeAnalyzer,
  Arbor.Core.HordeAgentRegistry
]

Enum.each(modules_to_check, fn module ->
  loaded = Code.ensure_loaded?(module)
  IO.puts("#{module}: #{if loaded, do: "✓ loaded", else: "✗ not loaded"}")
end)

# Check if Horde processes are running
horde_processes = [
  Arbor.Core.HordeAgentSupervisor,
  Arbor.Core.HordeAgentRegistry
]

Enum.each(horde_processes, fn name ->
  alive = Process.whereis(name) |> is_pid()
  IO.puts("#{name}: #{if alive, do: "✓ running", else: "✗ not running"}")
end)

# Check current registry contents
registry_count = Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [{{:_, :_, :_}, [], [:"$_"]}]) |> length()
IO.puts("Registry entries: #{registry_count}")

