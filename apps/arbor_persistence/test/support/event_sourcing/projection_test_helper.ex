defmodule Arbor.Persistence.ProjectionTestHelper do
  @moduledoc """
  Test utilities for event projections and read models.

  This module helps test CQRS read models by providing utilities to build
  projections from events, compare projection states, and handle async
  projection updates. It supports both synchronous and eventually consistent
  projection testing.

  ## Usage

      use Arbor.Persistence.FastCase
      import Arbor.Persistence.ProjectionTestHelper
      
      test "agent list projection", %{store: store} do
        # ... append events ...
        
        projection = build_projection(ActiveAgentsProjection, store)
        assert length(projection.active_agents) == 3
        
        # Compare with expected
        expected = %{active_agents: ["agent-1", "agent-2", "agent-3"]}
        assert_projection_matches(projection, expected)
      end
  """

  import ExUnit.Assertions
  alias Arbor.Persistence.Store

  @doc """
  Builds a projection by applying all events from the store.

  ## Parameters
  - `projection_module` - Module implementing projection behavior
  - `store` - The store instance
  - `opts` - Options (optional)
    - `:initial_state` - Starting projection state (default: from module)
    - `:stream_filter` - Function to filter relevant streams
    - `:event_filter` - Function to filter relevant events

  ## Examples

      # Simple projection
      projection = build_projection(AgentListProjection, store)
      
      # With filtering
      projection = build_projection(ActiveAgentsProjection, store,
        event_filter: fn event -> event.type in [:agent_started, :agent_stopped] end
      )
  """
  def build_projection(projection_module, store, opts \\ []) do
    initial_state = Keyword.get(opts, :initial_state, projection_module.init())
    stream_filter = Keyword.get(opts, :stream_filter, fn _ -> true end)
    event_filter = Keyword.get(opts, :event_filter, fn _ -> true end)

    # For testing, we'll read from all streams
    # In a real implementation, you'd have a global event log
    all_streams = list_all_streams(store)

    all_streams
    |> Enum.filter(stream_filter)
    |> Enum.reduce(initial_state, fn stream_id, projection_state ->
      {:ok, events} = Store.read_events(stream_id, 0, :latest, store)

      events
      |> Enum.filter(event_filter)
      |> Enum.reduce(projection_state, fn event, state ->
        projection_module.handle_event(event, state)
      end)
    end)
  end

  @doc """
  Compares two projections and returns differences.

  ## Parameters
  - `projection1` - First projection state
  - `projection2` - Second projection state
  - `opts` - Options (optional)
    - `:ignore_fields` - List of fields to ignore in comparison

  ## Returns
  - `{:ok, :identical}` - Projections are the same
  - `{:ok, differences}` - Map of differences

  ## Examples

      {:ok, diff} = compare_projections(before_projection, after_projection)
      assert diff.agent_count == {2, 3}
  """
  def compare_projections(projection1, projection2, opts \\ []) do
    ignore_fields = Keyword.get(opts, :ignore_fields, [:updated_at, :version])

    p1_map = to_comparable_map(projection1, ignore_fields)
    p2_map = to_comparable_map(projection2, ignore_fields)

    if p1_map == p2_map do
      {:ok, :identical}
    else
      differences = find_differences(p1_map, p2_map)
      {:ok, differences}
    end
  end

  @doc """
  Waits for an async projection to reach expected state.

  ## Parameters
  - `projection_fn` - Function that returns current projection state
  - `expected_state` - Expected state values to wait for
  - `opts` - Options (optional)
    - `:timeout` - Max wait time in ms (default: 5000)
    - `:interval` - Check interval in ms (default: 100)

  ## Examples

      wait_for_projection(
        fn -> AgentRegistry.get_active_count() end,
        %{count: 3},
        timeout: 2000
      )
  """
  def wait_for_projection(projection_fn, expected_state, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    interval = Keyword.get(opts, :interval, 100)

    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_projection_loop(projection_fn, expected_state, deadline, interval)
  end

  @doc """
  Asserts that a projection matches expected values.

  ## Parameters
  - `actual_projection` - The projection state to verify
  - `expected` - Map of expected values
  - `opts` - Options (optional)
    - `:only` - Only check these fields
    - `:except` - Ignore these fields

  ## Examples

      assert_projection_matches(projection, %{
        total_agents: 5,
        active_agents: ["agent-1", "agent-2"]
      })
      
      # Only check specific fields
      assert_projection_matches(projection, %{total_agents: 5}, only: [:total_agents])
  """
  def assert_projection_matches(actual_projection, expected, opts \\ []) do
    only_fields = Keyword.get(opts, :only)
    except_fields = Keyword.get(opts, :except, [])

    actual_map = to_comparable_map(actual_projection, except_fields)

    fields_to_check =
      if only_fields do
        only_fields
      else
        Map.keys(expected)
      end

    Enum.each(fields_to_check, fn field ->
      expected_value = Map.get(expected, field)
      actual_value = Map.get(actual_map, field)

      assert actual_value == expected_value,
             """
             Projection field mismatch: #{field}
             Expected: #{inspect(expected_value)}
             Actual:   #{inspect(actual_value)}
             Full projection: #{inspect(actual_map)}
             """
    end)
  end

  @doc """
  Creates a snapshot test for a projection.

  ## Parameters
  - `name` - Snapshot identifier
  - `projection` - The projection to snapshot
  - `opts` - Options (optional)
    - `:update` - Update snapshot if different (default: false)

  ## Examples

      projection = build_projection(StatsProjection, store)
      assert_projection_snapshot("stats_after_setup", projection)
  """
  def assert_projection_snapshot(name, projection, opts \\ []) do
    update = Keyword.get(opts, :update, false)
    snapshot_dir = "test/snapshots"
    snapshot_file = Path.join(snapshot_dir, "#{name}.snapshot")

    # Ensure directory exists
    File.mkdir_p!(snapshot_dir)

    current_snapshot = serialize_projection(projection)

    if File.exists?(snapshot_file) do
      stored_snapshot = File.read!(snapshot_file)

      if current_snapshot == stored_snapshot do
        assert true
      else
        if update do
          File.write!(snapshot_file, current_snapshot)
          IO.puts("Updated snapshot: #{name}")
          assert true
        else
          assert false,
                 """
                 Projection snapshot mismatch for: #{name}

                 Run with update: true to update the snapshot, or verify the differences:

                 Expected (stored):
                 #{stored_snapshot}

                 Actual (current):
                 #{current_snapshot}
                 """
        end
      end
    else
      # First time - create snapshot
      File.write!(snapshot_file, current_snapshot)
      IO.puts("Created snapshot: #{name}")
      assert true
    end
  end

  @doc """
  Builds multiple projections and returns them as a map.

  ## Parameters
  - `projection_modules` - List of projection modules or {name, module} tuples
  - `store` - The store instance
  - `opts` - Options passed to each build_projection call

  ## Examples

      projections = build_projections([
        stats: StatsProjection,
        agents: AgentListProjection,
        timeline: TimelineProjection
      ], store)
      
      assert projections.stats.total_events == 10
      assert length(projections.agents.all) == 3
  """
  def build_projections(projection_modules, store, opts \\ []) do
    projection_modules
    |> Enum.map(fn
      {name, module} -> {name, build_projection(module, store, opts)}
      module -> {module, build_projection(module, store, opts)}
    end)
    |> Map.new()
  end

  # Example projection modules for testing

  defmodule ExampleProjections do
    @moduledoc false

    defmodule AgentCountProjection do
      @moduledoc false

      def init, do: %{total: 0, by_status: %{}}

      def handle_event(%{type: :agent_started} = event, state) do
        state
        |> Map.update!(:total, &(&1 + 1))
        |> update_in([:by_status, :started], &((&1 || 0) + 1))
      end

      def handle_event(%{type: :agent_activated}, state) do
        state
        |> update_in([:by_status, :started], &((&1 || 1) - 1))
        |> update_in([:by_status, :active], &((&1 || 0) + 1))
      end

      def handle_event(%{type: :agent_stopped}, state) do
        state
        |> Map.update!(:total, &(&1 - 1))
        |> update_in([:by_status, :active], &((&1 || 1) - 1))
      end

      def handle_event(_, state), do: state
    end
  end

  # Private helpers

  defp list_all_streams(store) do
    # This is a simplified version - in reality, you'd query the event store
    case store do
      %{backend: :in_memory, backend_state: %{config_table: config_table}} ->
        # Read stream versions from config table
        case :ets.lookup(config_table, :stream_versions) do
          [{:stream_versions, versions}] -> Map.keys(versions)
          [] -> []
        end

      _ ->
        # For other backends, would need different approach
        []
    end
  end

  defp to_comparable_map(projection, ignore_fields) when is_map(projection) do
    projection
    |> Map.drop(ignore_fields)
  end

  defp to_comparable_map(projection, ignore_fields) when is_struct(projection) do
    projection
    |> Map.from_struct()
    |> Map.drop(ignore_fields)
  end

  defp find_differences(map1, map2) do
    all_keys =
      MapSet.union(
        MapSet.new(Map.keys(map1)),
        MapSet.new(Map.keys(map2))
      )

    all_keys
    |> Enum.reduce(%{}, fn key, acc ->
      val1 = Map.get(map1, key)
      val2 = Map.get(map2, key)

      if val1 == val2 do
        acc
      else
        Map.put(acc, key, {val1, val2})
      end
    end)
  end

  defp wait_for_projection_loop(projection_fn, expected_state, deadline, interval) do
    current_time = System.monotonic_time(:millisecond)

    if current_time > deadline do
      current_state = projection_fn.()

      flunk("""
      Projection did not reach expected state within timeout
      Expected: #{inspect(expected_state)}
      Actual:   #{inspect(current_state)}
      """)
    end

    current_state = projection_fn.()

    if projection_matches?(current_state, expected_state) do
      :ok
    else
      Process.sleep(interval)
      wait_for_projection_loop(projection_fn, expected_state, deadline, interval)
    end
  end

  defp projection_matches?(current, expected) when is_map(current) and is_map(expected) do
    Enum.all?(expected, fn {key, value} ->
      Map.get(current, key) == value
    end)
  end

  defp projection_matches?(current, expected) do
    current == expected
  end

  defp serialize_projection(projection) do
    projection
    |> to_comparable_map([:updated_at, :version])
    |> Jason.encode!(pretty: true)
  end
end
