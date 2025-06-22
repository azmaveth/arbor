defmodule Arbor.Persistence.HotCache do
  @moduledoc """
  ETS-based hot storage cache for session state and fast recovery.

  This module implements the "hot tier" of the multi-tiered persistence
  architecture. It provides microsecond access times for frequently
  accessed data.

  ## Design Principles

  - **High Performance**: ETS tables with read/write concurrency
  - **Process Isolation**: Each cache runs in its own GenServer
  - **Named Tables**: Tables can be accessed directly by name for debugging
  - **Thread Safety**: Concurrent reads and writes supported

  ## Crash Recovery

  Current implementation: ETS tables are tied to the GenServer lifecycle.
  For true crash recovery, would need supervisor-based table inheritance.

  ## Usage

      {:ok, cache} = HotCache.start_link(table_name: :session_cache)

      :ok = HotCache.put(cache, "session_123", session_state)
      {:ok, state} = HotCache.get(cache, "session_123")

      :ok = HotCache.delete(cache, "session_123")
  """

  use GenServer

  @type cache_key :: String.t() | atom()
  @type cache_value :: any()
  @type cache_info :: %{
          size: non_neg_integer(),
          memory: non_neg_integer(),
          type: atom(),
          named_table: boolean()
        }

  # Public API

  @doc """
  Start a new cache GenServer.

  ## Options

  - `:table_name` - Name for the ETS table (default: generated unique name)
  - `:ets_opts` - Additional ETS options (default: optimized for read/write concurrency)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Store a value in the cache.
  """
  @spec put(GenServer.server(), cache_key(), cache_value()) :: :ok
  def put(cache, key, value) do
    GenServer.call(cache, {:put, key, value})
  end

  @doc """
  Retrieve a value from the cache.
  """
  @spec get(GenServer.server(), cache_key()) :: {:ok, cache_value()} | {:error, :not_found}
  def get(cache, key) do
    GenServer.call(cache, {:get, key})
  end

  @doc """
  Remove a value from the cache.
  """
  @spec delete(GenServer.server(), cache_key()) :: :ok
  def delete(cache, key) do
    GenServer.call(cache, {:delete, key})
  end

  @doc """
  List all keys in the cache.
  """
  @spec list_keys(GenServer.server()) :: {:ok, [cache_key()]}
  def list_keys(cache) do
    GenServer.call(cache, :list_keys)
  end

  @doc """
  Clear all entries from the cache.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(cache) do
    GenServer.call(cache, :clear)
  end

  @doc """
  Get the number of entries in the cache.
  """
  @spec size(GenServer.server()) :: {:ok, non_neg_integer()}
  def size(cache) do
    GenServer.call(cache, :size)
  end

  @doc """
  Get cache information and statistics.
  """
  @spec get_info(GenServer.server()) :: {:ok, cache_info()}
  def get_info(cache) do
    GenServer.call(cache, :get_info)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, generate_table_name())
    ets_opts = Keyword.get(opts, :ets_opts, default_ets_opts())

    # Create ETS table with optimized settings
    table = :ets.new(table_name, ets_opts)

    state = %{
      table: table,
      table_name: table_name
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    :ets.insert(state.table, {key, value})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    case :ets.lookup(state.table, key) do
      [{^key, value}] -> {:reply, {:ok, value}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_keys, _from, state) do
    keys = :ets.foldl(fn {key, _value}, acc -> [key | acc] end, [], state.table)
    {:reply, {:ok, keys}, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:size, _from, state) do
    size = :ets.info(state.table, :size)
    {:reply, {:ok, size}, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      size: :ets.info(state.table, :size),
      memory: :ets.info(state.table, :memory),
      type: :ets.info(state.table, :type),
      named_table: :ets.info(state.table, :named_table)
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up ETS table if it's not named (named tables survive process death)
    unless :ets.info(state.table, :named_table) do
      :ets.delete(state.table)
    end

    :ok
  end

  # Private functions

  defp generate_table_name do
    :"hot_cache_#{:erlang.unique_integer([:positive])}"
  end

  defp default_ets_opts do
    [
      # Key-value store with unique keys
      :set,
      # Other processes can access
      :public,
      # Can be accessed by name
      :named_table,
      # Optimize for concurrent reads
      {:read_concurrency, true},
      # Optimize for concurrent writes
      {:write_concurrency, true}
      # Note: For true crash recovery, would need {:heir, supervisor_pid}
      # Current implementation: table dies with process
    ]
  end
end
