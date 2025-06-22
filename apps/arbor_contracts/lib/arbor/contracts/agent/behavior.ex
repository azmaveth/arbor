defmodule Arbor.Contracts.Agent.Behavior do
  @moduledoc """
  Defines the contract for an agent's core behavior and state management.

  This contract specifies the functions an agent must implement to integrate
  with advanced features of the Arbor runtime, such as state migration,
  metadata exposure, and handling registration outcomes.

  Implementing this behavior is crucial for agents that need to be resilient
  across restarts or deployments, and for those that need to interact with
  system-level services like a central registry.
  """

  @typedoc "The agent's internal state."
  @type agent_state :: any()

  @typedoc "The agent's specification, typically containing configuration."
  @type agent_spec :: map()

  @typedoc "Metadata about the agent."
  @type metadata :: map()

  @typedoc "The reason for a failure or the result of an operation."
  @type reason :: any()

  @doc """
  Extracts the agent's serializable state.

  This function is called before an agent is stopped for a planned migration
  or a graceful shutdown. The returned state should be serializable so it can
  be persisted and later used by `restore_state/2`.

  ## Arguments

    - `agent_state`: The current internal state of the agent process.

  ## Return Values

    - `{:ok, serializable_state}`: The extracted state.
    - `{:error, reason}`: If state extraction fails.
  """
  @callback extract_state(agent_state :: agent_state()) :: {:ok, any()} | {:error, reason()}

  @doc """
  Restores the agent's state from a previously extracted state.

  This function is called during the agent's initialization process, allowing
  it to resume from where it left off.

  ## Arguments

    - `agent_spec`: The agent's specification, which may contain initial config.
    - `restored_state`: The state returned by `extract_state/1`.

  ## Return Values

    - `{:ok, new_agent_state}`: The fully restored internal state for the agent.
    - `{:error, reason}`: If state restoration fails.
  """
  @callback restore_state(agent_spec :: agent_spec(), restored_state :: any()) ::
              {:ok, agent_state()} | {:error, reason()}

  @doc """
  Returns agent-specific metadata.

  This metadata can be used by monitoring, discovery, or management tools
  to understand the agent's capabilities, version, or other relevant details.

  ## Arguments

    - `agent_state`: The current internal state of the agent process.

  ## Return Values

  A map containing arbitrary metadata about the agent.
  """
  @callback get_agent_metadata(agent_state :: agent_state()) :: metadata()

  @doc """
  Handles the result of an agent's registration attempt.

  After an agent starts, the system may attempt to register it with a central
  registry. This callback informs the agent of the outcome.

  ## Arguments

    - `agent_state`: The current internal state of the agent process.
    - `result`: `{:ok, registration_data}` or `{:error, reason}`.

  ## Return Values

  The updated agent state.
  """
  @callback handle_registration_result(
              agent_state :: agent_state(),
              result :: {:ok, any()} | {:error, reason()}
            ) :: agent_state()
end
