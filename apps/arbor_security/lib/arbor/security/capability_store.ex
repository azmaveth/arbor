defmodule Arbor.Security.CapabilityStore do
  @moduledoc """
  Capability storage backend using PostgreSQL + ETS caching.

  This module provides persistent storage for capabilities with fast
  in-memory caching. It implements a write-through cache pattern:
  - All writes go to PostgreSQL first, then ETS
  - Reads try ETS first, fall back to PostgreSQL
  - Cache invalidation on updates/deletes

  The ETS cache provides sub-millisecond read performance for
  authorization decisions while PostgreSQL ensures durability
  and consistency across restarts.
  """

  use GenServer

  alias Arbor.Contracts.Core.Capability

  require Logger

  @table_name :capability_cache
  # 1 hour TTL for cached capabilities
  @cache_ttl_seconds 3600

  defstruct [
    :ets_table,
    :db_module,
    :cache_stats
  ]

  @type state :: %__MODULE__{
          ets_table: :ets.table(),
          db_module: module(),
          cache_stats: map()
        }

  # Client API

  @doc """
  Start the capability store.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store a capability in both PostgreSQL and ETS cache.
  """
  @spec store_capability(Capability.t()) :: :ok | {:error, term()}
  def store_capability(%Capability{} = capability) do
    GenServer.call(__MODULE__, {:store_capability, capability})
  end

  @doc """
  Get a capability by ID, trying cache first.
  """
  @spec get_capability(String.t()) :: {:ok, Capability.t()} | {:error, :not_found}
  def get_capability(capability_id) do
    GenServer.call(__MODULE__, {:get_capability, capability_id})
  end

  @doc """
  Get a capability from cache only (fast path).
  """
  @spec get_capability_cached(String.t()) :: {:ok, Capability.t()} | {:error, :not_found}
  def get_capability_cached(capability_id) do
    GenServer.call(__MODULE__, {:get_capability_cached, capability_id})
  end

  @doc """
  Revoke a capability (remove from storage).
  """
  @spec revoke_capability(String.t(), atom(), String.t(), boolean()) :: :ok | {:error, term()}
  def revoke_capability(capability_id, reason, revoker_id, cascade) do
    GenServer.call(__MODULE__, {:revoke_capability, capability_id, reason, revoker_id, cascade})
  end

  @doc """
  List all capabilities for a principal.
  """
  @spec list_capabilities(String.t(), keyword()) :: {:ok, [Capability.t()]} | {:error, term()}
  def list_capabilities(principal_id, filters \\ []) do
    GenServer.call(__MODULE__, {:list_capabilities, principal_id, filters})
  end

  @doc """
  Get cache statistics.
  """
  @spec get_cache_stats() :: map()
  def get_cache_stats do
    GenServer.call(__MODULE__, :get_cache_stats)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    # Create ETS table for caching
    # Use :protected so only the owner process can write
    ets_table =
      :ets.new(@table_name, [
        :set,
        # Only owner can write, others can read
        :protected,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    # Use real PostgreSQL repo by default, mock for testing
    db_module =
      opts[:db_module] ||
        (Application.get_env(:arbor_security, :env, :dev) == :test && opts[:use_mock] &&
           __MODULE__.PostgresDB) ||
        Arbor.Security.Persistence.CapabilityRepo

    state = %__MODULE__{
      ets_table: ets_table,
      db_module: db_module,
      cache_stats: %{hits: 0, misses: 0, writes: 0, deletes: 0}
    }

    Logger.info("CapabilityStore started with ETS table #{inspect(ets_table)}")

    {:ok, state}
  end

  @impl true
  def handle_call({:store_capability, capability}, _from, state) do
    case store_capability_impl(capability, state) do
      :ok ->
        new_stats = update_stats(state.cache_stats, :writes, 1)
        {:reply, :ok, %{state | cache_stats: new_stats}}

      {:error, reason} = error ->
        Logger.error("Failed to store capability #{capability.id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_capability, capability_id}, _from, state) do
    case get_capability_impl(capability_id, state) do
      {:ok, capability, :cache} ->
        new_stats = update_stats(state.cache_stats, :hits, 1)
        {:reply, {:ok, capability}, %{state | cache_stats: new_stats}}

      {:ok, capability, :db} ->
        new_stats = update_stats(state.cache_stats, :misses, 1)
        {:reply, {:ok, capability}, %{state | cache_stats: new_stats}}

      {:error, :not_found} = error ->
        new_stats = update_stats(state.cache_stats, :misses, 1)
        {:reply, error, %{state | cache_stats: new_stats}}

      {:error, reason} = error ->
        Logger.error("Failed to get capability #{capability_id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_capability_cached, capability_id}, _from, state) do
    case get_from_cache(capability_id, state) do
      {:ok, capability} ->
        new_stats = update_stats(state.cache_stats, :hits, 1)
        {:reply, {:ok, capability}, %{state | cache_stats: new_stats}}

      {:error, :not_found} = error ->
        new_stats = update_stats(state.cache_stats, :misses, 1)
        {:reply, error, %{state | cache_stats: new_stats}}
    end
  end

  @impl true
  def handle_call({:revoke_capability, capability_id, reason, revoker_id, cascade}, _from, state) do
    case revoke_capability_impl(capability_id, reason, revoker_id, cascade, state) do
      :ok ->
        new_stats = update_stats(state.cache_stats, :deletes, 1)
        {:reply, :ok, %{state | cache_stats: new_stats}}

      {:error, reason} = error ->
        Logger.error("Failed to revoke capability #{capability_id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:list_capabilities, principal_id, filters}, _from, state) do
    case list_capabilities_impl(principal_id, filters, state) do
      {:ok, capabilities} ->
        {:reply, {:ok, capabilities}, state}

      {:error, reason} = error ->
        Logger.error("Failed to list capabilities for #{principal_id}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_cache_stats, _from, state) do
    # Add ETS table info to stats
    table_info =
      try do
        %{
          size: :ets.info(state.ets_table, :size),
          memory: :ets.info(state.ets_table, :memory)
        }
      rescue
        _ -> %{size: 0, memory: 0}
      end

    stats = Map.merge(state.cache_stats, table_info)
    {:reply, stats, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("CapabilityStore terminating: #{inspect(reason)}")

    # Clean up ETS table
    if :ets.info(state.ets_table) != :undefined do
      :ets.delete(state.ets_table)
    end

    :ok
  end

  # Private implementation functions

  defp store_capability_impl(capability, state) do
    # Write-through pattern: PostgreSQL first, then cache
    with :ok <- state.db_module.insert_capability(capability),
         :ok <- put_in_cache(capability, state) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_capability_impl(capability_id, state) do
    # Try cache first
    case get_from_cache(capability_id, state) do
      {:ok, capability} ->
        {:ok, capability, :cache}

      {:error, :not_found} ->
        # Fall back to database
        case state.db_module.get_capability(capability_id) do
          {:ok, capability} ->
            # Store in cache for next time
            :ok = put_in_cache(capability, state)
            {:ok, capability, :db}

          {:error, :not_found} = error ->
            error

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp revoke_capability_impl(capability_id, reason, revoker_id, cascade, state) do
    # Remove from database first
    with :ok <- state.db_module.delete_capability(capability_id, reason, revoker_id),
         :ok <- remove_from_cache(capability_id, state) do
      # Handle cascade deletion if requested
      if cascade do
        handle_cascade_revocation(capability_id, state)
      end

      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_capabilities_impl(principal_id, filters, state) do
    # For now, we'll go directly to the database for list operations
    # In a more optimized version, we could maintain secondary indexes in ETS
    state.db_module.list_capabilities(principal_id, filters)
  end

  defp put_in_cache(capability, state) do
    # Store capability with TTL
    cache_entry = {capability, cache_expiry()}
    :ets.insert(state.ets_table, {capability.id, cache_entry})
    :ok
  end

  defp get_from_cache(capability_id, state) do
    case :ets.lookup(state.ets_table, capability_id) do
      [{^capability_id, {capability, expiry}}] ->
        if DateTime.compare(DateTime.utc_now(), expiry) == :lt do
          {:ok, capability}
        else
          # Expired entry, remove it
          :ets.delete(state.ets_table, capability_id)
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  defp remove_from_cache(capability_id, state) do
    :ets.delete(state.ets_table, capability_id)
    :ok
  end

  defp cache_expiry do
    DateTime.add(DateTime.utc_now(), @cache_ttl_seconds, :second)
  end

  defp update_stats(stats, key, increment) do
    Map.update(stats, key, increment, &(&1 + increment))
  end

  defp handle_cascade_revocation(capability_id, state) do
    case state.db_module.get_delegated_capabilities(capability_id) do
      {:ok, delegated_caps} ->
        Enum.each(delegated_caps, fn delegated_cap ->
          revoke_capability_impl(
            delegated_cap.id,
            :cascade_revocation,
            "system",
            false,
            state
          )
        end)

      {:error, _reason} ->
        # Log error but don't fail the primary revocation
        Logger.warning("Failed to get delegated capabilities for cascade revocation")
    end
  end

  # Mock PostgreSQL module for development/testing
  defmodule PostgresDB do
    @moduledoc """
    Mock PostgreSQL database module for testing.

    TODO: This is a mock implementation for testing only!
    In production, use Arbor.Security.Persistence.CapabilityRepo instead.
    This uses Agent-based in-memory storage which is NOT suitable for production.

    FIXME: All data is lost on restart - not suitable for production use!
    """

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{capabilities: %{}, sequence: 0} end, name: __MODULE__)
    end

    def insert_capability(capability) do
      Agent.update(__MODULE__, fn state ->
        %{state | capabilities: Map.put(state.capabilities, capability.id, capability)}
      end)

      :ok
    end

    def get_capability(capability_id) do
      case Agent.get(__MODULE__, fn state -> Map.get(state.capabilities, capability_id) end) do
        nil -> {:error, :not_found}
        capability -> {:ok, capability}
      end
    end

    def delete_capability(capability_id, _reason, _revoker_id) do
      Agent.update(__MODULE__, fn state ->
        %{state | capabilities: Map.delete(state.capabilities, capability_id)}
      end)

      :ok
    end

    def list_capabilities(principal_id, _filters) do
      capabilities =
        Agent.get(__MODULE__, fn state ->
          state.capabilities
          |> Map.values()
          |> Enum.filter(&(&1.principal_id == principal_id))
        end)

      {:ok, capabilities}
    end

    def get_delegated_capabilities(parent_capability_id) do
      capabilities =
        Agent.get(__MODULE__, fn state ->
          state.capabilities
          |> Map.values()
          |> Enum.filter(&(&1.parent_capability_id == parent_capability_id))
        end)

      {:ok, capabilities}
    end

    def clear_all do
      Agent.update(__MODULE__, fn _state ->
        %{capabilities: %{}, sequence: 0}
      end)

      :ok
    end
  end
end
