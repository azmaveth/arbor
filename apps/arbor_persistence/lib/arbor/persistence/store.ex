defmodule Arbor.Persistence.Store do
  @moduledoc """
  Production implementation of the Arbor.Contracts.Persistence.Store behavior.

  This module provides the main persistence interface for the Arbor system,
  implementing event sourcing, snapshots, and transactional operations.

  ## Implementation Strategy

  - **Unit Tests**: Use in-memory mock backend for fast, isolated testing
  - **Integration Tests**: Use real PostgreSQL backend via Docker
  - **Production**: PostgreSQL with connection pooling and transactions

  ## Usage in Tests

      # MOCK: Use in-memory backend for unit tests
      {:ok, store} = Store.init(backend: :in_memory, table_name: :test_store)
      
      # Production: Use PostgreSQL backend
      {:ok, store} = Store.init(backend: :postgresql, repo: MyRepo)
  """

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Events.Event, as: ContractEvent
  alias Arbor.Contracts.Persistence.Snapshot, as: ContractSnapshot
  alias Arbor.Persistence.{HotCache, Repo}
  alias Arbor.Persistence.Schemas.{Event, Snapshot}
  alias Arbor.Test.Mocks.InMemoryPersistence

  import Ecto.Query

  @type backend :: :in_memory | :postgresql
  @type store_state :: %{
          backend: backend(),
          backend_state: any()
        }

  @impl true
  def init(opts) do
    backend = Keyword.get(opts, :backend, :in_memory)

    case backend do
      :in_memory ->
        # MOCK: Use in-memory implementation for testing
        {:ok, backend_state} = InMemoryPersistence.init(opts)

        {:ok,
         %{
           backend: :in_memory,
           backend_state: backend_state
         }}

      :postgresql ->
        # Initialize PostgreSQL backend with ETS cache
        cache_table = Keyword.get(opts, :cache_table, :store_cache)
        {:ok, cache_pid} = HotCache.start_link(table_name: cache_table)

        {:ok,
         %{
           backend: :postgresql,
           cache: cache_pid,
           cache_table: cache_table
         }}
    end
  end

  @impl true
  def append_events(stream_id, events, expected_version, %{backend: :in_memory} = state) do
    # MOCK: Delegate to in-memory implementation
    with {:ok, contract_events} <- validate_and_convert_events(events),
         {:ok, version} <-
           InMemoryPersistence.append_events(
             stream_id,
             contract_events,
             expected_version,
             state.backend_state
           ) do
      {:ok, version}
    end
  end

  @impl true
  def append_events(stream_id, events, expected_version, %{backend: :postgresql} = state) do
    with {:ok, contract_events} <- validate_and_convert_events(events),
         {:ok, final_version} <-
           append_events_to_postgresql(stream_id, contract_events, expected_version),
         :ok <- update_cache_after_append(stream_id, contract_events, state) do
      {:ok, final_version}
    end
  end

  @impl true
  def read_events(stream_id, from_version, to_version, %{backend: :in_memory} = state) do
    # MOCK: Delegate to in-memory implementation
    with :ok <- validate_version_range(from_version, to_version),
         {:ok, contract_events} <-
           InMemoryPersistence.read_events(
             stream_id,
             from_version,
             to_version,
             state.backend_state
           ) do
      {:ok, contract_events}
    end
  end

  @impl true
  def read_events(stream_id, from_version, to_version, %{backend: :postgresql} = state) do
    with :ok <- validate_version_range(from_version, to_version),
         {:ok, events} <- read_events_from_cache_or_db(stream_id, from_version, to_version, state) do
      {:ok, events}
    end
  end

  @impl true
  def read_all_events(from, to, opts, %{backend: :in_memory} = state) do
    # MOCK: Delegate to in-memory implementation
    InMemoryPersistence.read_all_events(from, to, opts, state.backend_state)
  end

  @impl true
  def read_all_events(from, to, opts, %{backend: :postgresql} = _state) do
    # Read all events from database within time range
    query =
      from(e in Event,
        where: e.occurred_at >= ^from and e.occurred_at <= ^to,
        order_by: [asc: e.occurred_at]
      )

    # Apply optional filters
    query = apply_event_filters(query, opts)

    db_events = Repo.all(query)
    contract_events = Enum.map(db_events, &Event.to_contract/1)

    {:ok, contract_events}
  end

  @impl true
  def save_snapshot(stream_id, snapshot, %{backend: :in_memory} = state) do
    # MOCK: Delegate to in-memory implementation
    with :ok <- validate_snapshot(snapshot) do
      InMemoryPersistence.save_snapshot(stream_id, snapshot, state.backend_state)
    end
  end

  @impl true
  def save_snapshot(stream_id, snapshot, %{backend: :postgresql} = state) do
    with :ok <- validate_snapshot(snapshot),
         {:ok, snapshot_id} <- save_snapshot_to_postgresql(stream_id, snapshot),
         :ok <- invalidate_snapshot_cache(stream_id, state) do
      {:ok, snapshot_id}
    end
  end

  @impl true
  def load_snapshot(stream_id, %{backend: :in_memory} = state) do
    # MOCK: Delegate to in-memory implementation
    InMemoryPersistence.load_snapshot(stream_id, state.backend_state)
  end

  @impl true
  def load_snapshot(stream_id, %{backend: :postgresql} = state) do
    load_snapshot_from_cache_or_db(stream_id, state)
  end

  @impl true
  def delete_stream(stream_id, %{backend: :in_memory} = state) do
    # MOCK: Delegate to in-memory implementation
    InMemoryPersistence.delete_stream(stream_id, state.backend_state)
  end

  @impl true
  def list_streams(pattern, %{backend: :in_memory} = state) do
    # MOCK: Delegate to in-memory implementation
    InMemoryPersistence.list_streams(pattern, state.backend_state)
  end

  @impl true
  def get_stream_metadata(stream_id, %{backend: :in_memory} = state) do
    # MOCK: Delegate to in-memory implementation
    InMemoryPersistence.get_stream_metadata(stream_id, state.backend_state)
  end

  @impl true
  def get_stream_metadata(stream_id, %{backend: :postgresql} = _state) do
    get_stream_metadata_from_db(stream_id)
  end

  @impl true
  def transaction(fun, opts, %{backend: :in_memory} = state) do
    # MOCK: Delegate to in-memory implementation
    # Wrap the function to pass the correct state format
    wrapped_fun = fn backend_state ->
      fun.(%{state | backend_state: backend_state})
    end

    InMemoryPersistence.transaction(wrapped_fun, opts, state.backend_state)
  end

  @impl true
  def transaction(fun, _opts, %{backend: :postgresql} = state) do
    Repo.transaction(fn ->
      fun.(state)
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def terminate(reason, %{backend: :in_memory} = state) do
    # MOCK: Delegate to in-memory implementation
    InMemoryPersistence.terminate(reason, state.backend_state)
  end

  # Private validation functions

  defp validate_and_convert_events([]) do
    {:error, {:invalid_params, :empty_events}}
  end

  defp validate_and_convert_events(events) when is_list(events) do
    # Convert and validate each event
    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, acc} ->
      case validate_event_for_append(event) do
        :ok -> {:cont, {:ok, [event | acc]}}
        {:error, reason} -> {:halt, {:error, {:validation_error, reason}}}
      end
    end)
    |> case do
      {:ok, validated_events} -> {:ok, Enum.reverse(validated_events)}
      error -> error
    end
  end

  defp validate_event_for_append(%ContractEvent{aggregate_id: nil}) do
    {:error, :missing_aggregate_id}
  end

  defp validate_event_for_append(%ContractEvent{aggregate_id: ""}),
    do: {:error, :missing_aggregate_id}

  defp validate_event_for_append(%ContractEvent{type: nil}) do
    {:error, :missing_event_type}
  end

  defp validate_event_for_append(%ContractEvent{data: nil}) do
    {:error, :missing_event_data}
  end

  defp validate_event_for_append(%ContractEvent{}), do: :ok

  defp validate_event_for_append(_invalid) do
    {:error, :invalid_event_format}
  end

  defp validate_version_range(from, to) when is_integer(to) and from > to do
    {:error, {:invalid_params, :invalid_version_range}}
  end

  defp validate_version_range(_from, _to), do: :ok

  defp validate_snapshot(%ContractSnapshot{aggregate_id: nil}) do
    {:error, {:validation_error, :missing_aggregate_id}}
  end

  defp validate_snapshot(%ContractSnapshot{aggregate_id: ""}),
    do: {:error, {:validation_error, :missing_aggregate_id}}

  defp validate_snapshot(%ContractSnapshot{}), do: :ok

  defp validate_snapshot(_invalid) do
    {:error, {:validation_error, :invalid_snapshot_format}}
  end

  # PostgreSQL Backend Implementation

  defp append_events_to_postgresql(stream_id, events, expected_version) do
    Repo.transaction(fn ->
      # Check current version for optimistic locking
      current_version = get_current_stream_version(stream_id)

      if expected_version != -1 and current_version != expected_version do
        Repo.rollback(:version_conflict)
      else
        # Convert events to database format and insert
        db_event_maps =
          events
          |> Enum.with_index(current_version + 1)
          |> Enum.map(fn {event, version} ->
            event
            |> set_stream_info(stream_id, version)
            |> Event.to_map()
          end)

        # Insert all events
        {count, _} = Repo.insert_all(Event, db_event_maps, returning: [:stream_version])

        if count == length(events) do
          current_version + count
        else
          Repo.rollback(:insert_failed)
        end
      end
    end)
    |> case do
      {:ok, final_version} -> {:ok, final_version}
      {:error, :version_conflict} -> {:error, :version_conflict}
      {:error, _reason} -> {:error, :database_error}
    end
  end

  defp get_current_stream_version(stream_id) do
    case Repo.one(
           from(e in Event,
             where: e.stream_id == ^stream_id,
             select: max(e.stream_version)
           )
         ) do
      nil -> -1
      version -> version
    end
  end

  defp set_stream_info(event, stream_id, version) do
    %{event | stream_id: stream_id, stream_version: version}
  end

  defp read_events_from_cache_or_db(stream_id, from_version, to_version, state) do
    # Try cache first
    cache_key = "events:#{stream_id}:#{from_version}:#{to_version}"

    case HotCache.get(state.cache, cache_key) do
      {:ok, cached_events} ->
        {:ok, cached_events}

      {:error, :not_found} ->
        # Read from database
        query =
          from(e in Event,
            where: e.stream_id == ^stream_id and e.stream_version >= ^from_version,
            order_by: [asc: e.stream_version]
          )

        query =
          if to_version == :latest do
            query
          else
            where(query, [e], e.stream_version <= ^to_version)
          end

        db_events = Repo.all(query)
        contract_events = Enum.map(db_events, &Event.to_contract/1)

        # Cache the results
        HotCache.put(state.cache, cache_key, contract_events)

        {:ok, contract_events}
    end
  end

  defp update_cache_after_append(stream_id, _events, state) do
    # Invalidate relevant cache entries
    # For simplicity, we'll clear all cache entries for this stream
    # In production, could be more granular
    case HotCache.list_keys(state.cache) do
      {:ok, keys} ->
        stream_keys =
          Enum.filter(keys, fn key ->
            String.starts_with?(to_string(key), "events:#{stream_id}:")
          end)

        Enum.each(stream_keys, fn key ->
          HotCache.delete(state.cache, key)
        end)

        :ok

      # Cache operation failed, but don't fail the append
      {:error, _} ->
        :ok
    end
  end

  defp apply_event_filters(query, opts) do
    query
    |> apply_stream_filter(opts[:stream_filter])
    |> apply_event_types_filter(opts[:event_types])
    |> apply_limit_filter(opts[:limit])
  end

  defp apply_stream_filter(query, nil), do: query

  defp apply_stream_filter(query, pattern) do
    # Convert wildcard pattern to SQL LIKE pattern
    like_pattern = String.replace(pattern, "*", "%")
    where(query, [e], like(e.stream_id, ^like_pattern))
  end

  defp apply_event_types_filter(query, nil), do: query

  defp apply_event_types_filter(query, types) do
    string_types = Enum.map(types, &to_string/1)
    where(query, [e], e.event_type in ^string_types)
  end

  defp apply_limit_filter(query, nil), do: query

  defp apply_limit_filter(query, limit) do
    limit(query, ^limit)
  end

  defp save_snapshot_to_postgresql(stream_id, snapshot) do
    snapshot_map = Snapshot.to_map(snapshot, stream_id)

    # Use ON CONFLICT to replace existing snapshot for this stream
    case Repo.insert_all(Snapshot, [snapshot_map],
           on_conflict: :replace_all,
           conflict_target: [:stream_id],
           returning: [:id]
         ) do
      {1, [%{id: snapshot_id}]} -> {:ok, snapshot_id}
      _ -> {:error, :database_error}
    end
  end

  defp invalidate_snapshot_cache(stream_id, state) do
    cache_key = "snapshot:#{stream_id}"
    HotCache.delete(state.cache, cache_key)
    :ok
  end

  defp load_snapshot_from_cache_or_db(stream_id, state) do
    cache_key = "snapshot:#{stream_id}"

    case HotCache.get(state.cache, cache_key) do
      {:ok, cached_snapshot} ->
        {:ok, cached_snapshot}

      {:error, :not_found} ->
        case Repo.get_by(Snapshot, stream_id: stream_id) do
          nil ->
            {:error, :snapshot_not_found}

          db_snapshot ->
            contract_snapshot = Snapshot.to_contract(db_snapshot)
            HotCache.put(state.cache, cache_key, contract_snapshot)
            {:ok, contract_snapshot}
        end
    end
  end

  defp get_stream_metadata_from_db(stream_id) do
    # Check if stream exists by querying for events
    case Repo.one(
           from(e in Event,
             where: e.stream_id == ^stream_id,
             select: %{
               version: max(e.stream_version),
               event_count: count(e.id),
               created_at: min(e.occurred_at),
               updated_at: max(e.occurred_at)
             }
           )
         ) do
      nil ->
        {:error, :not_found}

      %{version: nil} ->
        {:error, :not_found}

      stats ->
        # Check if snapshot exists
        has_snapshot =
          case Repo.get_by(Snapshot, stream_id: stream_id) do
            nil -> false
            _ -> true
          end

        metadata = %{
          version: stats.version,
          event_count: stats.event_count,
          created_at: stats.created_at,
          updated_at: stats.updated_at,
          has_snapshot: has_snapshot
        }

        {:ok, metadata}
    end
  end
end
