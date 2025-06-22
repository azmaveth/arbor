defmodule Arbor.Test.Mocks.InMemoryPersistence do
  @moduledoc """
  TEST MOCK - DO NOT USE IN PRODUCTION

  In-memory implementation of the persistence store for testing.
  All data is stored in ETS tables and is lost when the process terminates.

  This mock is designed to:
  - Provide fast, deterministic tests
  - Simulate persistence behavior without external dependencies
  - Support testing of error conditions

  ## Usage in Tests

      defmodule MyTest do
        use ExUnit.Case

        setup do
          {:ok, store} = Arbor.Test.Mocks.InMemoryPersistence.init(table_name: :test_store)
          {:ok, store: store}
        end

        test "append and read events", %{store: store} do
          events = [%Event{type: :test_event, data: %{value: 1}}]
          {:ok, version} = InMemoryPersistence.append_events("stream_1", events, -1, store)
          assert version == 0
        end
      end

  ## Simulating Errors

  The mock supports error injection for testing error handling:

      # Configure to fail on next append
      :ets.insert(store.config_table, {:fail_next_append, true})

      # Configure to simulate version conflict
      :ets.insert(store.config_table, {:simulate_version_conflict, true})

  @warning This is a TEST MOCK - not for production use!
  """

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Events.Event

  defstruct [:events_table, :snapshots_table, :config_table]

  @impl true
  def init(opts) do
    table_name = opts[:table_name] || :mock_persistence

    events_table = :"#{table_name}_events"
    snapshots_table = :"#{table_name}_snapshots"
    config_table = :"#{table_name}_config"

    :ets.new(events_table, [:bag, :public, :named_table])
    :ets.new(snapshots_table, [:set, :public, :named_table])
    :ets.new(config_table, [:set, :public, :named_table])

    # Initialize stream version tracking
    :ets.insert(config_table, {:stream_versions, %{}})

    state = %__MODULE__{
      events_table: events_table,
      snapshots_table: snapshots_table,
      config_table: config_table
    }

    {:ok, state}
  end

  @impl true
  def append_events(stream_id, events, expected_version, state) do
    # Check for error injection
    if get_config(state, :fail_next_append) do
      clear_config(state, :fail_next_append)
      {:error, :mock_append_failure}
    else
      handle_append_with_version_check(stream_id, events, expected_version, state)
    end
  end

  defp handle_append_with_version_check(stream_id, events, expected_version, state) do
    case check_version(stream_id, expected_version, state) do
      :ok ->
        do_append_events(stream_id, events, state)

      {:error, _} = error ->
        if get_config(state, :simulate_version_conflict) do
          clear_config(state, :simulate_version_conflict)
          {:error, :version_conflict}
        else
          error
        end
    end
  end

  @impl true
  def read_events(stream_id, from_version, to_version, state) do
    events = :ets.lookup(state.events_table, stream_id)

    filtered =
      events
      |> Enum.map(fn {_, event} -> event end)
      |> Enum.filter(fn event ->
        event.stream_version >= from_version and
          (to_version == :latest or event.stream_version <= to_version)
      end)
      |> Enum.sort_by(& &1.stream_version)

    {:ok, filtered}
  end

  @impl true
  def read_all_events(from, to, opts, state) do
    all_events = :ets.tab2list(state.events_table)

    filtered =
      all_events
      |> Enum.map(fn {_, event} -> event end)
      |> Enum.filter(fn event ->
        DateTime.compare(event.timestamp, from) != :lt and
          DateTime.compare(event.timestamp, to) != :gt
      end)
      |> Enum.sort_by(& &1.timestamp)

    # Apply optional filters
    filtered =
      if opts[:stream_filter] do
        pattern = Regex.compile!(opts[:stream_filter])

        Enum.filter(filtered, fn event ->
          Regex.match?(pattern, event.stream_id || "")
        end)
      else
        filtered
      end

    filtered =
      if opts[:event_types] do
        types = MapSet.new(opts[:event_types])

        Enum.filter(filtered, fn event ->
          MapSet.member?(types, event.type)
        end)
      else
        filtered
      end

    # Apply limit
    filtered =
      if opts[:limit] do
        Enum.take(filtered, opts[:limit])
      else
        filtered
      end

    {:ok, filtered}
  end

  @impl true
  def save_snapshot(stream_id, snapshot, state) do
    snapshot_id = Map.get(snapshot, :id) || generate_snapshot_id()
    snapshot_with_id = Map.put(snapshot, :id, snapshot_id)
    :ets.insert(state.snapshots_table, {stream_id, snapshot_with_id})
    {:ok, snapshot_id}
  end

  @impl true
  def load_snapshot(stream_id, state) do
    case :ets.lookup(state.snapshots_table, stream_id) do
      [{_, snapshot}] -> {:ok, snapshot}
      [] -> {:error, :snapshot_not_found}
    end
  end

  @impl true
  def delete_stream(stream_id, state) do
    # Check if stream exists
    if stream_exists?(stream_id, state) do
      :ets.match_delete(state.events_table, {stream_id, :_})
      :ets.delete(state.snapshots_table, stream_id)
      remove_stream_version(stream_id, state)
      :ok
    else
      {:error, :not_found}
    end
  end

  @impl true
  def list_streams(pattern, state) do
    [{:stream_versions, versions}] = :ets.lookup(state.config_table, :stream_versions)

    streams = Map.keys(versions)

    # Simple pattern matching (supports * wildcard)
    regex_pattern =
      pattern
      |> String.replace("*", ".*")
      |> Regex.compile!()

    matching = Enum.filter(streams, &Regex.match?(regex_pattern, &1))
    {:ok, matching}
  end

  @impl true
  def get_stream_metadata(stream_id, state) do
    if stream_exists?(stream_id, state) do
      version = get_stream_version(stream_id, state)
      events = :ets.lookup(state.events_table, stream_id)

      timestamps =
        events
        |> Enum.map(fn {_, event} -> event.timestamp end)
        |> Enum.sort()

      has_snapshot =
        case :ets.lookup(state.snapshots_table, stream_id) do
          [] -> false
          _ -> true
        end

      metadata = %{
        version: version,
        event_count: length(events),
        created_at: List.first(timestamps),
        updated_at: List.last(timestamps),
        has_snapshot: has_snapshot
      }

      {:ok, metadata}
    else
      {:error, :not_found}
    end
  end

  @impl true
  def transaction(fun, _opts, state) do
    # Simple transaction simulation - just execute the function
    # In a real implementation, this would provide ACID guarantees
    fun.(state)
  rescue
    _ -> {:error, :transaction_failed}
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up ETS tables
    :ets.delete(state.events_table)
    :ets.delete(state.snapshots_table)
    :ets.delete(state.config_table)
    :ok
  end

  # Private functions

  defp check_version(stream_id, expected_version, state) do
    current_version = get_stream_version(stream_id, state)

    cond do
      expected_version == -1 and current_version == -1 -> :ok
      expected_version == current_version -> :ok
      true -> {:error, :version_conflict}
    end
  end

  defp do_append_events(stream_id, events, state) do
    current_version = get_stream_version(stream_id, state)

    {new_events, new_version} =
      events
      |> Enum.with_index(current_version + 1)
      |> Enum.map(fn {event, version} ->
        {Event.set_position(event, stream_id, version, version), version}
      end)
      |> Enum.unzip()

    # Store events
    Enum.each(new_events, fn event ->
      :ets.insert(state.events_table, {stream_id, event})
    end)

    # Update version
    final_version = List.last(new_version) || current_version
    update_stream_version(stream_id, final_version, state)

    {:ok, final_version}
  end

  defp get_stream_version(stream_id, state) do
    [{:stream_versions, versions}] = :ets.lookup(state.config_table, :stream_versions)
    Map.get(versions, stream_id, -1)
  end

  defp update_stream_version(stream_id, version, state) do
    [{:stream_versions, versions}] = :ets.lookup(state.config_table, :stream_versions)
    updated = Map.put(versions, stream_id, version)
    :ets.insert(state.config_table, {:stream_versions, updated})
  end

  defp remove_stream_version(stream_id, state) do
    [{:stream_versions, versions}] = :ets.lookup(state.config_table, :stream_versions)
    updated = Map.delete(versions, stream_id)
    :ets.insert(state.config_table, {:stream_versions, updated})
  end

  defp stream_exists?(stream_id, state) do
    get_stream_version(stream_id, state) != -1
  end

  defp get_config(state, key) do
    case :ets.lookup(state.config_table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp clear_config(state, key) do
    :ets.delete(state.config_table, key)
  end

  defp generate_snapshot_id do
    "snap_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end
end
