defmodule Arbor.Test.Mocks.TestAgent do
  @moduledoc """
  Simple test agent for supervision testing.
  MOCK: Replace with real agent implementations.
  """

  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(args) do
    state = Keyword.get(args, :initial_state, %{})
    {:ok, state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_cast({:set_state, new_state}, _state) do
    {:noreply, new_state}
  end

  def handle_cast({:add_agent, _agent_id}, state) do
    # Mock: Just acknowledge the cast
    {:noreply, state}
  end

  def handle_cast(_msg, state) do
    # Catch-all for any other casts
    {:noreply, state}
  end
end
