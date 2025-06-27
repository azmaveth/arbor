defmodule Arbor.Core.HordeCheckpointRegistry do
  @moduledoc """
  A dedicated process that acts as a stable anchor for checkpoint storage.

  This GenServer process is started as part of the supervision tree and remains
  alive throughout the application lifecycle. All checkpoints are registered
  to this process's PID, ensuring they survive when individual agent processes die.
  """

  @behaviour Arbor.Contracts.Cluster.CheckpointRegistry
  use GenServer

  require Logger

  @registry_name Arbor.Core.HordeCheckpointRegistry

  # Client API

  @doc """
  Starts the checkpoint registry anchor process.
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: :checkpoint_registry_anchor)
  end

  @impl true
  def start_service(config) do
    # Start the checkpoint registry service
    start_link(config)
  end

  @impl true
  def stop_service(reason) do
    # Stop the checkpoint registry service
    GenServer.stop(:checkpoint_registry_anchor, reason)
    :ok
  end

  @impl true
  def get_status do
    # Return the status of the checkpoint registry
    {:ok, %{status: :healthy, pid: Process.whereis(:checkpoint_registry_anchor)}}
  end

  @doc """
  Saves a checkpoint by registering it to the stable anchor process.
  """
  @spec save_checkpoint(checkpoint_key :: term(), checkpoint_data :: term()) ::
          :ok | {:error, term()}
  def save_checkpoint(checkpoint_key, checkpoint_data) do
    GenServer.call(
      :checkpoint_registry_anchor,
      {:save_checkpoint, checkpoint_key, checkpoint_data}
    )
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting HordeCheckpointRegistry anchor process at #{inspect(self())}")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:save_checkpoint, checkpoint_key, checkpoint_data}, _from, state) do
    # Register the checkpoint to our stable PID
    result =
      case Horde.Registry.register(@registry_name, checkpoint_key, checkpoint_data) do
        {:ok, _} ->
          :ok

        {:error, {:already_registered, _pid}} ->
          # Unregister and re-register to update
          Horde.Registry.unregister(@registry_name, checkpoint_key)

          case Horde.Registry.register(@registry_name, checkpoint_key, checkpoint_data) do
            {:ok, _} -> :ok
            error -> error
          end

        error ->
          error
      end

    {:reply, result, state}
  end
end
