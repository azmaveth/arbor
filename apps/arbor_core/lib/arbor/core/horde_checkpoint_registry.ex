defmodule Arbor.Core.HordeCheckpointRegistry do
  @moduledoc """
  A dedicated process that acts as a stable anchor for checkpoint storage.

  This GenServer process is started as part of the supervision tree and remains
  alive throughout the application lifecycle. All checkpoints are registered
  to this process's PID, ensuring they survive when individual agent processes die.
  """
  use GenServer

  require Logger

  @registry_name Arbor.Core.HordeCheckpointRegistry

  # Client API

  @doc """
  Starts the checkpoint registry anchor process.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: :checkpoint_registry_anchor)
  end

  @doc """
  Saves a checkpoint by registering it to the stable anchor process.
  """
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
