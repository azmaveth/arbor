defmodule Arbor.Core.StatefulTestAgent do
  @moduledoc """
  A test agent that implements the checkpoint behavior for demonstration
  and testing of stateful agent recovery capabilities.
  
  This agent periodically saves its state and can recover from failures
  by restoring the last checkpoint.
  """
  
  use GenServer
  @behaviour Arbor.Core.AgentCheckpoint
  
  alias Arbor.Core.{HordeRegistry, AgentCheckpoint}
  require Logger
  
  # Client API
  
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end
  
  def increment_counter(pid) do
    GenServer.cast(pid, :increment)
  end
  
  def set_value(pid, key, value) do
    GenServer.cast(pid, {:set_value, key, value})
  end
  
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end
  
  def save_checkpoint_now(pid) do
    GenServer.cast(pid, :checkpoint)
  end
  
  # GenServer callbacks
  
  @impl GenServer
  def init(args) do
    agent_id = Keyword.get(args, :agent_id)
    _agent_metadata = Keyword.get(args, :agent_metadata, %{})
    recovered_state = Keyword.get(args, :recovered_state)
    
    # Try to load from checkpoint if no recovered state provided
    state = case recovered_state do
      nil ->
        # Try to load from checkpoint
        case AgentCheckpoint.load_checkpoint(agent_id) do
          {:ok, checkpoint_data} ->
            Logger.info("StatefulTestAgent #{agent_id} loaded checkpoint during init", 
              counter: checkpoint_data.counter
            )
            %{
              agent_id: agent_id,
              counter: checkpoint_data.counter,
              data: checkpoint_data.data,
              started_at: System.system_time(:millisecond),
              checkpoint_count: checkpoint_data.checkpoint_count,
              recovered: true
            }
          {:error, :not_found} ->
            Logger.info("StatefulTestAgent #{agent_id} starting fresh (no checkpoint)")
            %{
              agent_id: agent_id,
              counter: 0,
              data: %{},
              started_at: System.system_time(:millisecond),
              checkpoint_count: 0,
              recovered: false
            }
        end
      recovered ->
        Logger.info("StatefulTestAgent #{agent_id} restored from provided state", 
          counter: recovered.counter,
          checkpoint_count: recovered.checkpoint_count
        )
        %{recovered | 
          started_at: System.system_time(:millisecond),
          recovered: true
        }
    end
    
    # Note: Agent registration is now handled by HordeSupervisor (centralized)
    
    # Enable automatic checkpointing every 10 seconds
    AgentCheckpoint.enable_auto_checkpoint(self(), 10_000)
    
    Logger.info("StatefulTestAgent #{agent_id} initialized", 
      recovered: state.recovered,
      counter: state.counter
    )
    
    {:ok, state}
  end
  
  @impl GenServer
  def handle_cast(:increment, state) do
    new_state = %{state | counter: state.counter + 1}
    Logger.debug("Incremented counter to #{new_state.counter}")
    {:noreply, new_state}
  end
  
  @impl GenServer
  def handle_cast({:set_value, key, value}, state) do
    new_data = Map.put(state.data, key, value)
    new_state = %{state | data: new_data}
    Logger.debug("Set #{key} to #{inspect(value)}")
    {:noreply, new_state}
  end
  
  @impl GenServer
  def handle_cast(:checkpoint, state) do
    case AgentCheckpoint.save_checkpoint(state.agent_id, state) do
      :ok ->
        new_state = %{state | checkpoint_count: state.checkpoint_count + 1}
        Logger.debug("Saved checkpoint #{new_state.checkpoint_count} for agent #{state.agent_id}")
        
        # Schedule next automatic checkpoint
        AgentCheckpoint.enable_auto_checkpoint(self(), 10_000)
        
        {:noreply, new_state}
        
      {:error, reason} ->
        Logger.warning("Failed to save checkpoint: #{inspect(reason)}")
        {:noreply, state}
    end
  end
  
  @impl GenServer
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
  
  @impl GenServer
  def handle_call(:prepare_checkpoint, _from, state) do
    # Extract checkpoint data for migration/restore
    checkpoint_data = extract_checkpoint_data(state)
    {:reply, checkpoint_data, state}
  end
  
  @impl GenServer
  def handle_info(:checkpoint, state) do
    # Handle automatic checkpoint trigger
    handle_cast(:checkpoint, state)
  end
  
  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug("StatefulTestAgent received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end
  
  @impl GenServer
  def terminate(_reason, state) do
    # Save final checkpoint (registration cleanup handled by HordeSupervisor)
    if state.agent_id do
      AgentCheckpoint.save_checkpoint(state.agent_id, state)
    end
    Logger.info("StatefulTestAgent #{state.agent_id} terminated")
    :ok
  end
  
  # Checkpoint behavior implementation
  
  @impl AgentCheckpoint
  def extract_checkpoint_data(state) do
    # Return only essential state data (exclude runtime metadata)
    %{
      agent_id: state.agent_id,
      counter: state.counter,
      data: state.data,
      checkpoint_count: state.checkpoint_count,
      last_checkpoint: System.system_time(:millisecond)
    }
  end
  
  @impl AgentCheckpoint
  def restore_from_checkpoint(checkpoint_data, _current_state) do
    # Reconstruct state from checkpoint data
    %{
      agent_id: checkpoint_data.agent_id,
      counter: checkpoint_data.counter,
      data: checkpoint_data.data,
      checkpoint_count: checkpoint_data.checkpoint_count,
      last_checkpoint: checkpoint_data.last_checkpoint,
      recovered_at: System.system_time(:millisecond)
    }
  end
end