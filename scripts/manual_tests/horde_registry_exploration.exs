#!/usr/bin/env elixir

# Simple test script to understand Horde.Registry behavior

IO.puts("Starting Horde.Registry test...")

# Start a simple registry
{:ok, _} = Horde.Registry.start_link(
  name: TestRegistry,
  keys: :unique,
  members: :auto
)

# Register a simple entry
key = "test_key"
value = {:pid_value, %{metadata: "test"}}

IO.puts("\nRegistering with key: #{inspect(key)}, value: #{inspect(value)}")
result = Horde.Registry.register(TestRegistry, key, value)
IO.puts("Register result: #{inspect(result)}")

# Try different select patterns to see what works
IO.puts("\n--- Testing different select patterns ---")

# Pattern 1: Match everything
pattern1 = [{:"$1", :"$2", :"$3"}]
guards1 = []
body1 = [{:"$_"}]
result1 = Horde.Registry.select(TestRegistry, [{pattern1, guards1, body1}])
IO.puts("\nPattern 1 - Match all: #{inspect(pattern1)}")
IO.puts("Result: #{inspect(result1)}")

# Pattern 2: Match by key
pattern2 = {key, :"$1", :"$2"}
guards2 = []
body2 = [{:"$1", :"$2"}]
result2 = Horde.Registry.select(TestRegistry, [{pattern2, guards2, body2}])
IO.puts("\nPattern 2 - Match by key: #{inspect(pattern2)}")
IO.puts("Result: #{inspect(result2)}")

# Pattern 3: Return just the value
pattern3 = {key, :"$1", :"$2"}
guards3 = []
body3 = [:"$2"]
result3 = Horde.Registry.select(TestRegistry, [{pattern3, guards3, body3}])
IO.puts("\nPattern 3 - Return value only: #{inspect(pattern3)}")
IO.puts("Result: #{inspect(result3)}")

# Pattern 4: Return tuple of pid and value
pattern4 = {key, :"$1", :"$2"}
guards4 = []
body4 = [{{:"$1", :"$2"}}]
result4 = Horde.Registry.select(TestRegistry, [{pattern4, guards4, body4}])
IO.puts("\nPattern 4 - Return {pid, value}: #{inspect(pattern4)}")
IO.puts("Result: #{inspect(result4)}")

IO.puts("\n--- Test complete ---")