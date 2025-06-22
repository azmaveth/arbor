defmodule Arbor.Core.SessionRegistry do
  @moduledoc """
  Distributed session registry using Horde for cluster-wide session discovery.

  This registry provides distributed session lookup across the Arbor cluster.
  Sessions automatically register themselves in this registry during initialization
  and are automatically removed when they terminate.

  ## Usage

  The registry is started automatically as part of the Arbor.Core application
  supervision tree. Sessions register themselves, and the Sessions.Manager
  uses this registry for distributed lookups.

      # Look up a session (done by Sessions.Manager)
      case Horde.Registry.lookup(Arbor.Core.SessionRegistry, session_id) do
        [{pid, metadata}] -> {:ok, pid, metadata}
        [] -> {:error, :not_found}
      end

  ## Cluster Behavior

  - Sessions are visible across all nodes in the cluster
  - When nodes join/leave, session state is automatically synchronized
  - During netsplits, sessions on the minority side may be terminated upon healing
  - Registry conflicts are resolved by Horde using the configured strategy

  ## Metadata Format

  Session metadata stored in the registry includes:
  - `:created_at` - When the session was created
  - `:created_by` - Entity that created the session
  - `:timeout` - Session timeout in milliseconds
  - `:metadata` - Custom session metadata
  """

  alias Arbor.Types

  @doc """
  Child specification for supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || __MODULE__

    horde_opts = [
      name: name,
      keys: :unique,
      # Use process-based distribution for even load balancing
      distribution_strategy: Horde.Registry.DistributionStrategy.Process,
      # Handle registry conflicts by keeping the older process
      conflict_resolution: :ignore
    ]

    Horde.Registry.start_link(horde_opts)
  end

  @doc """
  Register a session with metadata.

  This is called automatically by Session processes during initialization.
  """
  @spec register_session(Types.session_id(), pid(), map()) :: :ok | {:error, term()}
  def register_session(session_id, pid, metadata) do
    case Horde.Registry.register(__MODULE__, session_id, metadata) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, existing_pid}} ->
        # Handle registration conflict
        if existing_pid == pid do
          # Same process trying to register again - this is OK
          :ok
        else
          # Different process has this session_id - this is a serious conflict
          {:error, {:session_conflict, existing_pid}}
        end
    end
  end

  @doc """
  Unregister a session.

  This is called automatically when sessions terminate, but can also
  be called explicitly for cleanup.
  """
  @spec unregister_session(Types.session_id()) :: :ok
  def unregister_session(session_id) do
    Horde.Registry.unregister(__MODULE__, session_id)
    :ok
  end

  @doc """
  Look up a session by ID.
  """
  @spec lookup_session(Types.session_id()) :: {:ok, {pid(), map()}} | {:error, :not_found}
  def lookup_session(session_id) do
    case Horde.Registry.lookup(__MODULE__, session_id) do
      [{pid, metadata}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, {pid, metadata}}
        else
          # Process is dead but registry entry still exists
          # Horde should clean this up automatically, but we can help
          unregister_session(session_id)
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  List all active sessions across the cluster.
  """
  @spec list_all_sessions() :: [
          %{id: Types.session_id(), pid: pid(), metadata: map(), node: node()}
        ]
  def list_all_sessions do
    # Get all registered sessions using a match pattern
    __MODULE__
    |> Horde.Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {id, pid, metadata} ->
      %{
        id: id,
        pid: pid,
        metadata: metadata,
        alive: Process.alive?(pid),
        node: node(pid)
      }
    end)
    |> Enum.filter(& &1.alive)
  end

  @doc """
  Get session count across the cluster.
  """
  @spec session_count() :: non_neg_integer()
  def session_count do
    __MODULE__
    |> Horde.Registry.select([{{:"$1", :"$2", :"$3"}, [], [true]}])
    |> length()
  end

  @doc """
  Update session metadata.
  """
  @spec update_session_metadata(Types.session_id(), map()) :: :ok | {:error, :not_found}
  def update_session_metadata(session_id, new_metadata) do
    case lookup_session(session_id) do
      {:ok, {pid, _old_metadata}} ->
        # Horde doesn't have an update function, so we need to unregister/register
        # This creates a brief window where the session isn't visible
        unregister_session(session_id)
        register_session(session_id, pid, new_metadata)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
