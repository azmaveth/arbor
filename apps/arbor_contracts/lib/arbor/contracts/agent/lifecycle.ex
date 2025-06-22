defmodule Arbor.Contracts.Agent.Lifecycle do
  @moduledoc """
  Defines the contract for an agent's lifecycle management.

  This contract outlines the expected callbacks for agents that are managed
  by the Arbor runtime. Implementing this behavior allows the system to
  start, stop, monitor, and recover agents in a standardized way.

  ## Agent States

  An agent can be in one of the following states:

  - `:specified` - The agent's specification exists, but it is not yet running.
  - `:starting` - The agent is in the process of being started.
  - `:running` - The agent has successfully started and is operational.
  - `:stopped` - The agent has been stopped gracefully.
  - `:failed` - The agent terminated due to an error.

  The lifecycle callbacks are hooks that are invoked at different points
  of the agent's life, allowing for custom logic to be executed during
  state transitions.
  """

  @typedoc "Represents the possible states of a managed agent."
  @type state :: :specified | :starting | :running | :stopped | :failed

  @typedoc "The reason for a state transition."
  @type reason :: any()

  @typedoc "The agent's specification, typically containing configuration."
  @type agent_spec :: map()

  @doc """
  Invoked when the agent is starting.

  This callback should handle the initialization of the agent's process.
  It typically involves starting a GenServer or another process.
  """
  @callback on_start(agent_spec :: agent_spec()) :: {:ok, pid()} | {:error, reason()}

  @doc """
  Invoked after the agent has successfully started and is ready for registration.

  This allows the agent to perform any necessary registration with other
  services or registries.
  """
  @callback on_register(pid :: pid(), agent_spec :: agent_spec()) :: :ok | {:error, reason()}

  @doc """
  Invoked when the agent is being stopped gracefully.

  This callback should handle the graceful termination of the agent's process.
  """
  @callback on_stop(pid :: pid(), reason :: reason()) :: :ok

  @doc """
  Invoked when the system is attempting to restart a failed agent.
  """
  @callback on_restart(agent_spec :: agent_spec(), reason :: reason()) ::
              {:ok, pid()} | {:error, reason()}

  @doc """
  Invoked when an agent has failed.

  This can be used for logging, cleanup, or notification purposes.
  """
  @callback on_fail(agent_spec :: agent_spec(), reason :: reason()) :: :ok

  @doc """
  Returns the current state of the agent.
  """
  @callback get_current_state(agent_spec :: agent_spec()) :: state()

  @doc """
  A convenience function to check if the agent is currently running.
  """
  @callback is_running?(agent_spec :: agent_spec()) :: boolean()
end
