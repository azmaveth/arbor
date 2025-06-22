defmodule Arbor.Test.Mocks.TestAgent do
  @moduledoc """
  Simple test agent for supervision testing that demonstrates self-registration.
  MOCK: Replace with real agent implementations.
  """

  use Arbor.Core.AgentBehavior

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl GenServer
  def init(args) do
    # Extract agent identity from args
    agent_id = Keyword.get(args, :agent_id)
    agent_metadata = Keyword.get(args, :agent_metadata, %{})
    initial_state = Keyword.get(args, :initial_state, %{})

    # Ensure initial_state is always a map for Map.merge
    base_state = if is_map(initial_state), do: initial_state, else: %{}

    state =
      Map.merge(base_state, %{
        agent_id: agent_id,
        agent_metadata: agent_metadata,
        registered_at: System.system_time(:millisecond)
      })

    {:ok, state, {:continue, :register_with_supervisor}}
  end

  @impl Arbor.Core.AgentBehavior
  def get_agent_metadata(state) do
    Map.get(state, :agent_metadata, %{})
  end

  @impl GenServer
  def handle_cast({:set_state, new_state}, _state) do
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_cast({:add_agent, _agent_id}, state) do
    # Mock: Just acknowledge the cast
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(_msg, state) do
    # Catch-all for any other casts
    {:noreply, state}
  end
end
