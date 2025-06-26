defmodule Arbor.Test.Mocks.TestAgent do
  @moduledoc """
  TEST MOCK - DO NOT USE IN PRODUCTION

  Simple agent implementation for testing purposes.

  @warning This is a TEST MOCK - for testing only!
  """

  use GenServer

  # Client API

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args)
  end

  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  def set_state(pid, new_state) do
    GenServer.call(pid, {:set_state, new_state})
  end

  # GenServer callbacks

  @impl true
  def init(args) do
    # For AgentBehavior compatibility, merge agent_id and metadata into state
    agent_id = Keyword.get(args, :agent_id)
    agent_metadata = Keyword.get(args, :agent_metadata, %{})

    initial_state =
      case args do
        [initial_state: state] when is_map(state) ->
          state

        [{:initial_state, state}] when is_map(state) ->
          state

        _ ->
          # Try to extract initial_state from keyword list
          Keyword.get(args, :initial_state, %{})
      end

    # Ensure state is a map and add agent info if provided
    state =
      if is_map(initial_state) do
        initial_state
      else
        %{initial_state: initial_state}
      end

    # Add agent_id and metadata to state if provided
    state = maybe_add_agent_info(state, agent_id, agent_metadata)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:set_state, new_state}, _from, _state) do
    {:reply, :ok, new_state}
  end

  # Support checkpoint operations for handoff testing
  @impl true
  def handle_call(:checkpoint, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_cast({:restore, checkpoint_state}, _state) do
    {:noreply, checkpoint_state}
  end

  # Private helpers
  defp maybe_add_agent_info(state, agent_id, agent_metadata) do
    state
    |> maybe_add_agent_id(agent_id)
    |> maybe_add_metadata(agent_metadata)
  end

  defp maybe_add_agent_id(state, nil), do: state
  defp maybe_add_agent_id(state, agent_id), do: Map.put(state, :agent_id, agent_id)

  defp maybe_add_metadata(state, metadata) when metadata == %{}, do: state
  defp maybe_add_metadata(state, metadata), do: Map.put(state, :agent_metadata, metadata)
end
