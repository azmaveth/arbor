defmodule Arbor.Test.Mocks.TestAgent do
  @moduledoc """
  Simple test agent for integration testing.

  This agent provides basic functionality needed for testing cluster events,
  supervision, and other distributed features without complex business logic.
  """

  use Arbor.Core.AgentBehavior

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @spec init(keyword()) :: {:ok, map(), {:continue, :register_with_supervisor}}
  def init(args) do
    agent_id = Keyword.get(args, :agent_id)

    state = %{
      agent_id: agent_id,
      value: Keyword.get(args, :initial_value, 0),
      started_at: System.system_time(:millisecond),
      restart_count: 0
    }

    {:ok, state, {:continue, :register_with_supervisor}}
  end

  # Test-specific functionality

  @spec get_value(pid()) :: integer()
  def get_value(pid) when is_pid(pid) do
    GenServer.call(pid, :get_value)
  end

  @spec increment(pid()) :: :ok
  def increment(pid) when is_pid(pid) do
    GenServer.cast(pid, :increment)
  end

  @spec get_restart_count(pid()) :: integer()
  def get_restart_count(pid) when is_pid(pid) do
    GenServer.call(pid, :get_restart_count)
  end

  # GenServer callbacks

  def handle_call(:get_value, _from, state) do
    {:reply, state.value, state}
  end

  def handle_call(:get_restart_count, _from, state) do
    {:reply, state.restart_count, state}
  end

  def handle_call(request, from, state) do
    # Delegate to AgentBehavior for standard agent operations
    super(request, from, state)
  end

  def handle_cast(:increment, state) do
    {:noreply, %{state | value: state.value + 1}}
  end

  def handle_cast(request, state) do
    # Delegate to AgentBehavior for standard agent operations  
    super(request, state)
  end

  def handle_info(info, state) do
    # Delegate to AgentBehavior for standard agent operations
    super(info, state)
  end

  # AgentBehavior implementation

  def extract_state(state) do
    {:ok, Map.take(state, [:agent_id, :value, :started_at, :restart_count])}
  end

  def restore_state(current_state, checkpoint_data) do
    restored_state = %{
      current_state
      | value: checkpoint_data.value,
        restart_count: checkpoint_data.restart_count + 1,
        recovered: true,
        recovered_at: System.system_time(:millisecond)
    }

    {:ok, restored_state}
  end

  def get_agent_metadata(state) do
    %{
      agent_id: state.agent_id,
      module: __MODULE__,
      started_at: state.started_at,
      restart_count: state.restart_count,
      value: state.value,
      status: :running
    }
  end
end
