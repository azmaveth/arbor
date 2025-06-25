defmodule Arbor.Core.AgentCheckpoint do
  @moduledoc """
  Provides checkpoint/restore capabilities for stateful agents.

  This module enables agents to save critical state that can be recovered
  after process failures or node migrations. Checkpoints are stored in
  the distributed Horde.Registry for cluster-wide availability.

  ## Usage

  For agents that need state persistence, implement the checkpoint callbacks:

      defmodule MyStatefulAgent do
        use GenServer
        @behaviour Arbor.Core.AgentCheckpoint

        def init(args) do
          # Try to recover from checkpoint
          case Arbor.Core.AgentCheckpoint.load_checkpoint(args[:agent_id]) do
            {:ok, saved_state} ->
              Logger.info("Agent \#{args[:agent_id]} recovered from checkpoint")
              {:ok, saved_state}
            {:error, :not_found} ->
              {:ok, %{agent_id: args[:agent_id], data: %{}}}
          end
        end

        def handle_cast(:checkpoint, state) do
          Arbor.Core.AgentCheckpoint.save_checkpoint(state.agent_id, state)
          {:noreply, state}
        end

        # Implement checkpoint behavior
        @impl Arbor.Core.AgentCheckpoint
        def extract_checkpoint_data(state) do
          # Return only essential state data
          %{
            agent_id: state.agent_id,
            important_data: state.important_data,
            last_processed: state.last_processed
          }
        end

        @impl Arbor.Core.AgentCheckpoint
        def restore_from_checkpoint(checkpoint_data, _current_state) do
          # Reconstruct state from checkpoint
          %{
            agent_id: checkpoint_data.agent_id,
            important_data: checkpoint_data.important_data,
            last_processed: checkpoint_data.last_processed,
            restored_at: System.system_time(:millisecond)
          }
        end
      end

  ## Automatic Checkpointing

  Agents can enable automatic periodic checkpointing:

      # In agent init/1
      Arbor.Core.AgentCheckpoint.enable_auto_checkpoint(self(), 30_000)  # Every 30 seconds

  ## Recovery During Reconciliation

  The AgentReconciler automatically attempts state recovery for agents that
  implement the checkpoint behavior.
  """

  @behaviour Arbor.Contracts.Agent.Checkpoint

  alias Arbor.Types
  require Logger

  @registry_name Arbor.Core.HordeCheckpointRegistry

  @type checkpoint_data :: any()
  @type agent_state :: any()

  @doc """
  Extract essential state data for checkpointing.

  This callback should return only the minimal data needed to restore
  the agent's critical state. Avoid including temporary data, cached
  values, or large datasets.
  """

  @doc """
  Restore agent state from checkpoint data.

  This callback receives the previously saved checkpoint data and the
  current initial state, and should return the restored state.
  """

  @doc """
  Save agent state to a persistent checkpoint.

  The checkpoint is stored in the distributed registry and will be
  available across all cluster nodes.
  """
  @spec save_checkpoint(Types.agent_id(), agent_state()) :: :ok | {:error, term()}
  def save_checkpoint(agent_id, state) when is_binary(agent_id) do
    timestamp = System.system_time(:millisecond)

    checkpoint_data = %{
      state: state,
      timestamp: timestamp,
      node: node(),
      version: 1
    }

    checkpoint_key = {:agent_checkpoint, agent_id}

    # Use the stable anchor process to save the checkpoint
    case Arbor.Core.HordeCheckpointRegistry.save_checkpoint(checkpoint_key, checkpoint_data) do
      :ok ->
        :telemetry.execute(
          [:arbor, :checkpoint, :saved],
          %{
            size_bytes: estimate_size(checkpoint_data)
          },
          %{
            agent_id: agent_id,
            node: node()
          }
        )

        :ok

      {:error, reason} ->
        Logger.warning("Failed to save checkpoint for agent #{agent_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Load agent state from a persistent checkpoint.

  Returns the previously saved state or {:error, :not_found} if no
  checkpoint exists for the agent.

  Due to the eventually consistent nature of Horde's CRDT, this function
  includes a retry mechanism for recently saved checkpoints.
  """
  @spec load_checkpoint(Types.agent_id()) :: {:ok, agent_state()} | {:error, :not_found | term()}
  def load_checkpoint(agent_id) when is_binary(agent_id) do
    load_checkpoint_with_retry(agent_id, 5, 100)
  end

  defp load_checkpoint_with_retry(agent_id, retries, delay) when retries > 0 do
    checkpoint_key = {:agent_checkpoint, agent_id}

    # Use select instead of lookup to avoid process liveness check
    pattern = {checkpoint_key, :"$1", :"$2"}
    guard = []
    body = [:"$2"]

    case Horde.Registry.select(@registry_name, [{pattern, guard, body}]) do
      [checkpoint_data] ->
        :telemetry.execute(
          [:arbor, :checkpoint, :loaded],
          %{
            age_ms: System.system_time(:millisecond) - checkpoint_data.timestamp,
            size_bytes: estimate_size(checkpoint_data)
          },
          %{
            agent_id: agent_id,
            original_node: checkpoint_data.node,
            current_node: node()
          }
        )

        {:ok, checkpoint_data.state}

      [] ->
        # Retry with exponential backoff for CRDT synchronization
        Process.sleep(delay)
        load_checkpoint_with_retry(agent_id, retries - 1, delay * 2)
    end
  rescue
    error ->
      :telemetry.execute([:arbor, :checkpoint, :load_failed], %{}, %{
        agent_id: agent_id,
        error: inspect(error),
        node: node()
      })

      {:error, error}
  end

  defp load_checkpoint_with_retry(agent_id, _retries, _delay) do
    :telemetry.execute([:arbor, :checkpoint, :not_found], %{}, %{
      agent_id: agent_id,
      node: node()
    })

    {:error, :not_found}
  end

  @doc """
  Remove a checkpoint for an agent.

  This is typically called when an agent is permanently stopped.
  """
  @spec remove_checkpoint(Types.agent_id()) :: :ok
  def remove_checkpoint(agent_id) when is_binary(agent_id) do
    checkpoint_key = {:agent_checkpoint, agent_id}

    Horde.Registry.unregister(@registry_name, checkpoint_key)

    :telemetry.execute([:arbor, :checkpoint, :removed], %{}, %{
      agent_id: agent_id,
      node: node()
    })

    :ok
  end

  @doc """
  Enable automatic periodic checkpointing for an agent.

  The agent process will receive `:checkpoint` messages at the specified
  interval. The agent should handle these messages by calling save_checkpoint/2.
  """
  @spec enable_auto_checkpoint(pid(), pos_integer()) :: :ok
  def enable_auto_checkpoint(agent_pid, interval_ms) when is_pid(agent_pid) and interval_ms > 0 do
    # Send initial checkpoint message after a delay
    Process.send_after(agent_pid, :checkpoint, interval_ms)
    :ok
  end

  @doc """
  Attempt to recover an agent's state using the checkpoint behavior.

  This function checks if the agent module implements the checkpoint behavior
  and attempts recovery. Used by AgentReconciler during agent restarts.
  """
  @spec attempt_state_recovery(module(), Types.agent_id(), keyword()) ::
          {:ok, agent_state()} | {:error, :no_checkpoint | :not_implemented | term()}
  def attempt_state_recovery(agent_module, agent_id, initial_args) do
    # Check if the module implements the checkpoint behavior
    Logger.debug("Checking if #{agent_module} implements checkpoint behavior")
    extract_exported = function_exported?(agent_module, :extract_checkpoint_data, 1)
    restore_exported = function_exported?(agent_module, :restore_from_checkpoint, 2)

    Logger.debug(
      "extract_checkpoint_data/1 exported: #{extract_exported}, restore_from_checkpoint/2 exported: #{restore_exported}"
    )

    if extract_exported and restore_exported do
      case load_checkpoint(agent_id) do
        {:ok, checkpoint_data} ->
          Logger.info("Loaded checkpoint for recovery",
            agent_id: agent_id
          )

          try do
            # Reconstruct initial state from args
            initial_state = %{
              agent_id: agent_id,
              args: initial_args,
              recovered: false
            }

            # Use the agent's restore callback
            restored_state = agent_module.restore_from_checkpoint(checkpoint_data, initial_state)

            Logger.info("Restored state from checkpoint",
              agent_id: agent_id
            )

            :telemetry.execute([:arbor, :recovery, :success], %{}, %{
              agent_id: agent_id,
              module: agent_module,
              node: node()
            })

            {:ok, restored_state}
          rescue
            error ->
              :telemetry.execute([:arbor, :recovery, :failed], %{}, %{
                agent_id: agent_id,
                module: agent_module,
                error: inspect(error),
                node: node()
              })

              {:error, error}
          end

        {:error, :not_found} ->
          Logger.warning("No checkpoint found for recovery", agent_id: agent_id)
          {:error, :no_checkpoint}

        {:error, reason} ->
          Logger.error("Failed to load checkpoint for recovery",
            agent_id: agent_id,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    else
      {:error, :not_implemented}
    end
  end

  @doc """
  Get checkpoint information for an agent.

  Returns metadata about the checkpoint without loading the full state.
  """
  @spec get_checkpoint_info(Types.agent_id()) ::
          {:ok, %{timestamp: integer(), node: node(), version: integer()}}
          | {:error, :not_found}
  def get_checkpoint_info(agent_id) when is_binary(agent_id) do
    checkpoint_key = {:agent_checkpoint, agent_id}

    # Use select instead of lookup to avoid process liveness check
    pattern = {checkpoint_key, :"$1", :"$2"}
    guard = []
    body = [:"$2"]

    case Horde.Registry.select(@registry_name, [{pattern, guard, body}]) do
      [checkpoint_data] ->
        info = %{
          timestamp: checkpoint_data.timestamp,
          node: checkpoint_data.node,
          version: checkpoint_data.version,
          age_ms: System.system_time(:millisecond) - checkpoint_data.timestamp
        }

        {:ok, info}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  List all agents that have checkpoints.

  Returns a list of agent IDs that have saved checkpoints.
  """
  @spec list_checkpointed_agents() :: [Types.agent_id()]
  def list_checkpointed_agents do
    pattern = {{:agent_checkpoint, :"$1"}, :"$2", :"$3"}
    guard = []
    body = [:"$1"]

    Horde.Registry.select(@registry_name, [{pattern, guard, body}])
  rescue
    _ -> []
  end

  # Private helpers

  defp estimate_size(data) do
    try do
      data |> :erlang.term_to_binary() |> byte_size()
    rescue
      _ -> 0
    end
  end
end
