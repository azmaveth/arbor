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

    # Self-register with the registry
    if agent_id do
      case register_self(agent_id, agent_metadata) do
        :ok ->
          Logger.info("TestAgent successfully registered",
            agent_id: agent_id,
            pid: inspect(self())
          )

        {:error, reason} ->
          Logger.error("TestAgent failed to register",
            agent_id: agent_id,
            reason: inspect(reason)
          )

          # Continue anyway for testing purposes
      end
    end

    state =
      Map.merge(initial_state, %{
        agent_id: agent_id,
        registered_at: System.system_time(:millisecond)
      })

    {:ok, state}
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
