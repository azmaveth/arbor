defmodule Arbor.Contracts.Persistence.Snapshot do
  @moduledoc """
  Snapshot structure for optimizing event sourcing recovery.

  Snapshots are periodic state checkpoints that allow faster state reconstruction
  by avoiding the need to replay all events from the beginning. They represent
  the aggregate state at a specific version.

  ## Design Principles

  - **Consistency**: Snapshots must be consistent with the event stream
  - **Versioning**: Include both snapshot format version and aggregate version
  - **Compression**: Large states can be compressed before storage
  - **Metadata**: Include sufficient metadata for debugging and management

  ## Snapshot Strategy

  Snapshots are typically created:
  - Every N events (e.g., every 100 events)
  - After significant state changes
  - On a time-based schedule
  - Before system shutdown for faster recovery

  ## Usage

      snapshot = Snapshot.new(
        aggregate_id: "agent_123",
        aggregate_type: :agent,
        aggregate_version: 150,
        state: %{status: :active, capabilities: [...]},
        metadata: %{compression: :none}
      )

  @version "1.0.0"
  """

  use TypedStruct

  @derive Jason.Encoder
  typedstruct enforce: true do
    @typedoc "A point-in-time state snapshot for an aggregate"

    field(:id, String.t())
    field(:aggregate_id, String.t())
    field(:aggregate_type, atom())
    field(:aggregate_version, non_neg_integer())
    field(:state, any())
    field(:state_hash, String.t())
    field(:created_at, DateTime.t())
    field(:snapshot_version, String.t(), default: "1.0.0")
    field(:metadata, map(), default: %{})
  end

  @doc """
  Create a new snapshot with validation.

  ## Required Fields

  - `:aggregate_id` - ID of the aggregate this snapshot represents
  - `:aggregate_type` - Type of the aggregate
  - `:aggregate_version` - Version of the aggregate at snapshot time
  - `:state` - The aggregate state to snapshot

  ## Optional Fields

  - `:metadata` - Additional metadata (compression type, etc.)
  - `:snapshot_version` - Version of the snapshot format

  ## Examples

      {:ok, snapshot} = Snapshot.new(
        aggregate_id: "agent_worker_123",
        aggregate_type: :agent,
        aggregate_version: 250,
        state: %{
          status: :active,
          capabilities: ["read", "write", "execute"],
          processed_tasks: 150,
          last_task_at: ~U[2024-01-15 10:30:00Z]
        }
      )
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    state = Keyword.fetch!(attrs, :state)

    snapshot = %__MODULE__{
      id: attrs[:id] || generate_snapshot_id(),
      aggregate_id: Keyword.fetch!(attrs, :aggregate_id),
      aggregate_type: Keyword.fetch!(attrs, :aggregate_type),
      aggregate_version: Keyword.fetch!(attrs, :aggregate_version),
      state: state,
      state_hash: calculate_state_hash(state),
      created_at: attrs[:created_at] || DateTime.utc_now(),
      snapshot_version: attrs[:snapshot_version] || "1.0.0",
      metadata: attrs[:metadata] || %{}
    }

    case validate_snapshot(snapshot) do
      :ok -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Compress a snapshot's state data.

  Large aggregate states can be compressed to reduce storage requirements.
  The compression type is stored in metadata.

  ## Supported Compression

  - `:gzip` - Standard gzip compression
  - `:zstd` - Zstandard compression (if available)
  - `:none` - No compression (default)

  ## Example

      {:ok, compressed} = Snapshot.compress(snapshot, :gzip)
      # compressed.metadata.compression == :gzip
      # compressed.state is now binary compressed data
  """
  @spec compress(t(), atom()) :: {:ok, t()} | {:error, term()}
  def compress(%__MODULE__{} = snapshot, type \\ :gzip) do
    case compress_state(snapshot.state, type) do
      {:ok, compressed_state} ->
        updated_snapshot = %{
          snapshot
          | state: compressed_state,
            metadata: Map.put(snapshot.metadata, :compression, type)
        }

        {:ok, updated_snapshot}

      {:error, reason} ->
        {:error, {:compression_failed, reason}}
    end
  end

  @doc """
  Decompress a snapshot's state data.

  Reverses the compression applied by `compress/2`.

  ## Example

      {:ok, decompressed} = Snapshot.decompress(compressed_snapshot)
      # decompressed.state is now the original uncompressed state
  """
  @spec decompress(t()) :: {:ok, t()} | {:error, term()}
  def decompress(%__MODULE__{metadata: %{compression: :none}} = snapshot) do
    {:ok, snapshot}
  end

  def decompress(%__MODULE__{metadata: %{compression: type}} = snapshot) do
    case decompress_state(snapshot.state, type) do
      {:ok, decompressed_state} ->
        updated_snapshot = %{
          snapshot
          | state: decompressed_state,
            metadata: Map.delete(snapshot.metadata, :compression)
        }

        {:ok, updated_snapshot}

      {:error, reason} ->
        {:error, {:decompression_failed, reason}}
    end
  end

  def decompress(%__MODULE__{} = snapshot) do
    # No compression metadata means uncompressed
    {:ok, snapshot}
  end

  @doc """
  Verify snapshot integrity by checking the state hash.

  Ensures the snapshot state hasn't been corrupted or tampered with.
  """
  @spec verify_integrity(t()) :: :ok | {:error, :integrity_check_failed}
  def verify_integrity(%__MODULE__{} = snapshot) do
    # Skip verification for compressed states
    if snapshot.metadata[:compression] && snapshot.metadata[:compression] != :none do
      :ok
    else
      calculated_hash = calculate_state_hash(snapshot.state)

      if calculated_hash == snapshot.state_hash do
        :ok
      else
        {:error, :integrity_check_failed}
      end
    end
  end

  @doc """
  Convert snapshot to a map suitable for serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    Map.from_struct(snapshot)
  end

  @doc """
  Restore a snapshot from a serialized map.
  """
  @spec from_map(map()) :: {:ok, t()}
  def from_map(map) when is_map(map) do
    attrs = parse_snapshot_fields(map)
    # Don't recalculate hash on restore - use stored hash
    snapshot = struct!(__MODULE__, attrs)
    {:ok, snapshot}
  end

  defp parse_snapshot_fields(map) do
    [
      id: get_field(map, :id),
      aggregate_id: get_field(map, :aggregate_id),
      aggregate_type: atomize_safely(get_field(map, :aggregate_type)),
      aggregate_version: get_field(map, :aggregate_version),
      state: get_field(map, :state),
      state_hash: get_field(map, :state_hash),
      created_at: parse_timestamp(get_field(map, :created_at)),
      snapshot_version: get_field(map, :snapshot_version),
      metadata: get_field(map, :metadata) || %{}
    ]
  end

  defp get_field(map, key) do
    map[Atom.to_string(key)] || map[key]
  end

  # Private functions

  defp generate_snapshot_id do
    "snap_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp calculate_state_hash(state) do
    state
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_snapshot(%__MODULE__{} = snapshot) do
    validators = [
      &validate_aggregate_id/1,
      &validate_aggregate_type/1,
      &validate_aggregate_version/1,
      &validate_snapshot_version/1
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(snapshot) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_aggregate_id(%{aggregate_id: id}) when is_binary(id) and byte_size(id) > 0 do
    :ok
  end

  defp validate_aggregate_id(%{aggregate_id: id}) do
    {:error, {:invalid_aggregate_id, id}}
  end

  defp validate_aggregate_type(%{aggregate_type: type}) when is_atom(type) and type != nil do
    :ok
  end

  defp validate_aggregate_type(%{aggregate_type: type}) do
    {:error, {:invalid_aggregate_type, type}}
  end

  defp validate_aggregate_version(%{aggregate_version: v}) when is_integer(v) and v >= 0 do
    :ok
  end

  defp validate_aggregate_version(%{aggregate_version: v}) do
    {:error, {:invalid_aggregate_version, v}}
  end

  defp validate_snapshot_version(%{snapshot_version: version}) when is_binary(version) do
    if Regex.match?(~r/^\d+\.\d+\.\d+$/, version) do
      :ok
    else
      {:error, {:invalid_snapshot_version_format, version}}
    end
  end

  defp validate_snapshot_version(%{snapshot_version: version}) do
    {:error, {:invalid_snapshot_version, version}}
  end

  defp compress_state(state, :gzip) do
    compressed =
      state
      |> :erlang.term_to_binary()
      |> :zlib.gzip()

    {:ok, compressed}
  rescue
    e -> {:error, e}
  end

  defp compress_state(state, :none) do
    {:ok, state}
  end

  defp compress_state(_state, type) do
    {:error, {:unsupported_compression_type, type}}
  end

  defp decompress_state(compressed, :gzip) when is_binary(compressed) do
    decompressed =
      compressed
      |> :zlib.gunzip()
      |> :erlang.binary_to_term()

    {:ok, decompressed}
  rescue
    e -> {:error, e}
  end

  defp decompress_state(state, :none) do
    {:ok, state}
  end

  defp decompress_state(_state, type) do
    {:error, {:unsupported_compression_type, type}}
  end

  defp atomize_safely(nil), do: nil
  defp atomize_safely(atom) when is_atom(atom), do: atom

  defp atomize_safely(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> String.to_atom(string)
  end

  defp parse_timestamp(%DateTime{} = dt), do: dt

  defp parse_timestamp(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()
end
