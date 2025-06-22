defmodule Arbor.Contracts.Agent.Reconciler do
  @moduledoc """
  Defines the contract for the agent reconciliation process.

  The reconciler is a system-level process responsible for ensuring that the
  actual state of running agents matches the desired state defined by their
  specifications. It periodically scans for discrepancies and takes corrective
  action.

  This contract outlines the key functions of the reconciliation loop.
  """

  @typedoc "The agent's specification, typically containing configuration."
  @type agent_spec :: map()

  @typedoc "The reason for a failure or restart."
  @type reason :: any()

  @doc """
  The main entry point for the reconciliation loop.

  This function orchestrates the entire reconciliation process, typically by
  calling other functions to find missing agents, clean up orphans, and
  ensure all specified agents are running correctly.
  """
  @callback reconcile_agents() :: :ok | {:error, reason()}

  @doc """
  Finds agents that have a specification but are not currently running.

  This function compares the list of desired agents (from a persistent store
  or configuration) with the list of currently running agent processes.

  ## Return Values

  A list of `agent_spec` maps for agents that need to be started.
  """
  @callback find_missing_agents() :: [agent_spec()]

  @doc """
  Finds and terminates running agent processes that do not have a
  corresponding specification.

  This is important for cleaning up resources from agents that have been
  removed from the configuration.
  """
  @callback cleanup_orphaned_processes() :: :ok

  @doc """
  Restarts a specific agent.

  This function should implement the logic for restarting an agent, potentially
  with a retry mechanism (e.g., exponential backoff) to avoid overwhelming
  the system if an agent is failing repeatedly.

  ## Arguments

    - `agent_spec`: The specification of the agent to restart.
    - `reason`: The reason for the restart.

  ## Return Values

    - `{:ok, pid}`: If the agent was restarted successfully.
    - `{:error, reason}`: If the restart failed.
  """
  @callback restart_agent(agent_spec :: agent_spec(), reason :: reason()) ::
              {:ok, pid()} | {:error, reason()}
end
