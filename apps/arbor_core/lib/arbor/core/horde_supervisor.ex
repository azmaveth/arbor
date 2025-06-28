defmodule Arbor.Core.HordeSupervisor do
  @moduledoc """
  Stateless wrapper around Horde.DynamicSupervisor for distributed agent management.

  This module provides the same API as the stateful HordeSupervisor but stores all
  agent metadata in the distributed Horde.Registry instead of local GenServer state.
  This eliminates the single point of failure while maintaining fault tolerance.

  ## Agent Process Lifecycle and Restart Strategy

  This system employs a two-tiered strategy to ensure both rapid recovery from
  transient faults and long-term consistency with the desired state.

  ### Tier 1: HordeSupervisor - Immediate Liveness

  The HordeSupervisor is responsible for the immediate liveness of agent processes.

  - **Strategy:** `:one_for_one`
  - **Responsibility:** If an agent process exits, HordeSupervisor will restart it
    according to its defined `restart_strategy` (`:permanent`, `:transient`, or `:temporary`).
  - **Scope:** Handles local process failures with millisecond-level recovery time.
  - **Limitation:** Unaware of global desired state, node failures, or config changes.

  ### Tier 2: AgentReconciler - Global State Reconciliation

  The AgentReconciler is a cluster-wide singleton responsible for ensuring the
  entire population of agents matches the centrally defined configuration.

  - **Strategy:** Periodically scans all running agents vs desired specifications
  - **Responsibility:** Handles coarse-grained, systemic changes including:
    - **Node Failures:** Redistributing agents from failed nodes to healthy nodes
    - **Specification Changes:** Rolling restarts when agent configuration updates
    - **Scaling:** Starting new agents when specs added, stopping when removed
    - **Consistency Audits:** Correcting drift from desired state

  ### Separation of Responsibilities

  | Concern | HordeSupervisor (Local) | AgentReconciler (Global) |
  |---------|-------------------------|--------------------------|
  | **Trigger** | Abnormal process exit | Periodic timer, node events, spec changes |
  | **Action** | Immediately restart failed process | Start/stop/move processes to match desired state |
  | **Recovery Time** | Milliseconds | Seconds to minutes (reconciliation interval) |
  | **Example** | Agent crashes due to bug | Node disconnects from cluster |

  ## Design

  - Agent specs are stored as persistent entries in Horde.Registry
  - Agent PIDs are registered separately for runtime lookups
  - AgentReconciler (singleton) ensures desired state matches actual state
  - No local state means no single point of failure

  ## Registry Key Structure

  - `{:agent, agent_id}` - Live agent PID and runtime metadata
  - `{:agent_spec, agent_id}` - Persistent agent specification for restarts
  """

  @behaviour Arbor.Contracts.Cluster.Supervisor
  @behaviour Arbor.Contracts.Agent.Lifecycle

  use GenServer

  alias Arbor.Contracts.Agent.Lifecycle
  alias Arbor.Contracts.Cluster.Supervisor, as: SupervisorContract
  alias Arbor.Core.{AgentCheckpoint, ClusterEvents, HordeRegistry}
  alias Horde.DynamicSupervisor

  require Logger

  # Configuration
  @supervisor_name Arbor.Core.HordeAgentSupervisor
  @registry_name Arbor.Core.HordeAgentRegistry
  @checkpoint_registry_name Arbor.Core.HordeCheckpointRegistry

  # ================================
  # GenServer API
  # ================================

  @doc """
  Starts the HordeSupervisor GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Centrally registers a running agent process.
  This is called by agents themselves after they have successfully started.
  """
  @spec register_agent(pid(), String.t(), map()) :: {:ok, pid()} | {:error, atom()}
  def register_agent(pid, agent_id, agent_specific_metadata) do
    GenServer.call(__MODULE__, {:register_agent, pid, agent_id, agent_specific_metadata})
  end

  # ================================
  # Service Lifecycle Callbacks
  # ================================

  @impl SupervisorContract
  def start_service(config) when is_list(config) do
    # Convert keyword list to map for contract compliance
    start_service(Enum.into(config, %{}))
  end

  def start_service(config) when is_map(config) do
    # HordeSupervisor is started as part of the supervision tree
    # This callback is for compatibility with the contract
    start_link(Enum.to_list(config))
  end

  @impl SupervisorContract
  def stop_service(_reason) do
    # HordeSupervisor is stopped as part of the supervision tree
    :ok
  end

  @impl SupervisorContract
  def get_status do
    # Return the status of the supervisor
    {:ok,
     %{
       status: :healthy,
       supervisor_name: @supervisor_name,
       registry_name: @registry_name
     }}
  end

  # ================================
  # SupervisorContract Implementation
  # ================================

  @impl SupervisorContract
  def start_agent(agent_spec) do
    agent_id = agent_spec.id
    spec_metadata = build_spec_metadata(agent_spec)

    case register_agent_spec(agent_id, spec_metadata) do
      :ok ->
        handle_successful_spec_registration(agent_id, agent_spec, spec_metadata)

      {:error, :already_started} ->
        {:error, :already_started}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl SupervisorContract
  def stop_agent(agent_id, _timeout \\ 5000) do
    # First look up the agent PID
    case HordeRegistry.lookup_agent_name(agent_id) do
      {:ok, pid, _metadata} ->
        # Terminate using the PID
        # Unregister from runtime registry first (centralized unregistration)
        HordeRegistry.unregister_agent_name(agent_id)

        case Horde.DynamicSupervisor.terminate_child(@supervisor_name, pid) do
          :ok ->
            # Remove the persistent spec
            unregister_agent_spec(agent_id)
            # Clean up any checkpoint data
            AgentCheckpoint.remove_checkpoint(agent_id)

            # Broadcast agent stop event
            ClusterEvents.broadcast(:agent_stopped, %{
              agent_id: agent_id,
              pid: pid,
              node: node()
            })

            Logger.info("Stopped and cleaned up agent #{agent_id}")
            :ok

          {:error, reason} ->
            Logger.warning("Failed to stop agent #{agent_id}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, :not_registered} ->
        # Agent not running, just clean up the spec and checkpoint
        unregister_agent_spec(agent_id)
        AgentCheckpoint.remove_checkpoint(agent_id)
        Logger.info("Cleaned up spec for non-running agent #{agent_id}")
        :ok
    end
  end

  @impl SupervisorContract
  def restart_agent(agent_id) do
    case lookup_agent_spec(agent_id) do
      {:ok, spec_metadata} ->
        # Stop if running, then start with original spec (no state recovery)
        _ = stop_agent(agent_id)

        agent_spec = %{
          id: agent_id,
          module: spec_metadata.module,
          args: spec_metadata.args,
          restart_strategy: spec_metadata.restart_strategy,
          metadata: spec_metadata.metadata
        }

        start_agent(agent_spec)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @impl SupervisorContract
  def restore_agent(agent_id) do
    case lookup_agent_spec(agent_id) do
      {:ok, spec_metadata} ->
        current_state = capture_agent_state(agent_id)

        case perform_soft_stop(agent_id) do
          :ok ->
            perform_agent_restart(agent_id, spec_metadata, current_state)

          {:error, :terminate_timeout} ->
            {:error, :terminate_timeout}
        end

      {:error, :not_found} ->
        {:error, :agent_not_found}
    end
  end

  @impl SupervisorContract
  def get_agent_info(agent_id) do
    with {:ok, spec_metadata} <- lookup_agent_spec(agent_id),
         {:ok, pid, runtime_metadata} <- HordeRegistry.lookup_agent_name(agent_id) do
      info = %{
        id: agent_id,
        pid: pid,
        node: node(pid),
        module: spec_metadata.module,
        restart_strategy: spec_metadata.restart_strategy,
        metadata: Map.merge(spec_metadata.metadata, runtime_metadata),
        created_at: spec_metadata.created_at,
        started_at: Map.get(runtime_metadata, :started_at, spec_metadata.created_at)
      }

      {:ok, info}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :not_registered} -> {:error, :not_found}
    end
  end

  @impl SupervisorContract
  def list_agents do
    # Get all agent specs
    case list_all_agent_specs() do
      {:ok, specs} ->
        agents =
          Enum.map(specs, fn {agent_id, spec_metadata} ->
            case HordeRegistry.lookup_agent_name(agent_id) do
              {:ok, pid, runtime_metadata} ->
                %{
                  id: agent_id,
                  pid: pid,
                  node: node(pid),
                  module: spec_metadata.module,
                  restart_strategy: spec_metadata.restart_strategy,
                  metadata: Map.merge(spec_metadata.metadata, runtime_metadata),
                  status: :running
                }

              {:error, :not_registered} ->
                %{
                  id: agent_id,
                  pid: nil,
                  node: nil,
                  module: spec_metadata.module,
                  restart_strategy: spec_metadata.restart_strategy,
                  metadata: spec_metadata.metadata,
                  status: :not_running
                }
            end
          end)

        {:ok, agents}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl SupervisorContract
  def health_metrics do
    cluster_members = Horde.Cluster.members(@supervisor_name)
    children = Horde.DynamicSupervisor.which_children(@supervisor_name)

    specs =
      case list_all_agent_specs() do
        {:ok, s} ->
          s

        {:error, _reason} ->
          # If spec lookup fails, we can't count total agents but can still report running ones.
          # Defaulting to an empty list allows the health check to succeed with partial data.
          Logger.warning(
            "Could not retrieve agent specs for health metrics. Reporting total_agents as 0."
          )

          []
      end

    metrics = %{
      total_agents: length(specs),
      running_agents: length(children),
      cluster_members: cluster_members,
      node_count: length(cluster_members)
    }

    {:ok, metrics}
  end

  @impl SupervisorContract
  def set_event_handler(_event_type, _callback) do
    # Event handling can be implemented via Phoenix.PubSub in Phase 3
    :ok
  end

  @spec handle_agent_handoff(binary(), atom(), map()) :: {:ok, any()} | {:error, any()}
  def handle_agent_handoff(agent_id, operation, state_data) do
    case operation do
      :handoff ->
        perform_state_handoff(agent_id)

      :takeover ->
        perform_state_takeover(agent_id, state_data)
    end
  end

  @impl SupervisorContract
  def update_agent_spec(agent_id, updates) do
    case lookup_agent_spec(agent_id) do
      {:ok, current_spec} ->
        updated_spec = Map.merge(current_spec, updates)
        register_agent_spec(agent_id, updated_spec)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # ================================
  # Agent.Lifecycle Implementation
  # ================================

  @impl Lifecycle
  def on_start(agent_spec) do
    start_agent(agent_spec)
  end

  @impl Lifecycle
  def on_register(pid, agent_spec) do
    metadata = Map.get(agent_spec, :metadata, %{})

    case register_agent(pid, agent_spec.id, metadata) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Lifecycle
  def on_stop(pid, reason) do
    case find_agent_id_by_pid(pid) do
      {:ok, agent_id} ->
        Logger.info(
          "Stopping agent #{agent_id} (PID: #{inspect(pid)}) due to: #{inspect(reason)}"
        )

        stop_agent(agent_id)

      {:error, :not_found} ->
        Logger.warning(
          "Attempted to stop an agent with PID #{inspect(pid)} that is not registered or its spec is missing."
        )

        :ok
    end
  end

  @impl Lifecycle
  def on_restart(agent_spec, reason) do
    Logger.info("Restarting agent #{agent_spec.id} due to: #{inspect(reason)}")
    restart_agent(agent_spec.id)
  end

  @impl Lifecycle
  def on_fail(agent_spec, reason) do
    Logger.error("Agent #{agent_spec.id} failed. Reason: #{inspect(reason)}")

    ClusterEvents.broadcast(:agent_failed, %{
      agent_id: agent_spec.id,
      reason: reason,
      agent_spec: agent_spec
    })

    :ok
  end

  @impl Lifecycle
  def get_current_state(agent_spec) do
    cond do
      is_running?(agent_spec) ->
        :running

      match?({:ok, _}, lookup_agent_spec(agent_spec.id)) ->
        :specified

      true ->
        # If spec is not found, it's considered stopped or never existed.
        :stopped
    end
  end

  @impl Lifecycle
  def is_running?(agent_spec) do
    case HordeRegistry.lookup_agent_name(agent_spec.id) do
      {:ok, pid, _metadata} -> Process.alive?(pid)
      _ -> false
    end
  end

  @doc """
  Look up agent specification from the distributed registry.

  Returns the stored agent specification that was registered when the agent was started.
  This includes the module, args, restart strategy, and metadata.

  ## Parameters

  - `agent_id` - ID of the agent to look up

  ## Returns

  - `{:ok, spec_metadata}` - Agent spec found
  - `{:error, :not_found}` - Agent spec not in registry
  """
  @spec lookup_agent_spec(binary()) :: {:ok, map()} | {:error, :not_found}
  def lookup_agent_spec(agent_id) do
    spec_key = {:agent_spec, agent_id}

    # Use select instead of lookup to avoid process liveness check
    pattern = {spec_key, :"$1", :"$2"}
    guard = []
    body = [:"$2"]

    case Horde.Registry.select(@registry_name, [{pattern, guard, body}]) do
      [] -> {:error, :not_found}
      [spec_metadata] -> {:ok, spec_metadata}
    end
  end

  @doc """
  Get supervisor cluster status.
  """
  @spec get_supervisor_status() :: %{
          members: [node()],
          agent_count: non_neg_integer(),
          status: :healthy | :degraded | :critical
        }
  def get_supervisor_status do
    # In test mode, return mock status
    case Application.get_env(:arbor_core, :supervisor_impl, :auto) do
      :mock ->
        %{
          members: [node()],
          agent_count: 0,
          status: :healthy
        }

      _ ->
        members = Horde.Cluster.members(@supervisor_name)

        agent_count =
          @supervisor_name
          |> Horde.DynamicSupervisor.which_children()
          |> length()

        status =
          cond do
            Enum.empty?(members) -> :critical
            length(members) == 1 -> :degraded
            true -> :healthy
          end

        %{
          members: members,
          agent_count: agent_count,
          status: status
        }
    end
  end

  # Compatibility functions for the current API

  @spec list_agents_by_node(node(), any()) :: {:ok, [map()]}
  def list_agents_by_node(node, _state \\ nil) do
    {:ok, agents} = list_agents()
    node_agents = Enum.filter(agents, fn agent -> agent.node == node end)
    {:ok, node_agents}
  end

  @spec extract_agent_state(String.t()) :: {:ok, any()} | {:error, term()}
  @impl true
  def extract_agent_state(agent_id) do
    # Simplified implementation to avoid complex handoff logic
    case HordeRegistry.lookup_agent_name(agent_id) do
      {:ok, pid, _metadata} ->
        # Try to extract state from agent
        try do
          GenServer.call(pid, :extract_state, 5000)
        catch
          _, _ -> {:ok, %{}}
        end

      _ ->
        {:error, :agent_not_found}
    end
  end

  @spec restore_agent_state(String.t(), map()) :: {:ok, any()} | {:error, term()}
  @impl true
  def restore_agent_state(agent_id, state_data) do
    handle_agent_handoff(agent_id, :takeover, state_data)
  end

  # ================================
  # GenServer Callbacks
  # ================================

  @impl true
  def init(_opts) do
    # Stateless
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register_agent, pid, agent_id, agent_specific_metadata}, _from, state) do
    case validate_process_alive(pid, agent_id) do
      :ok ->
        handle_agent_registration(pid, agent_id, agent_specific_metadata, state)

      error_reply ->
        error_reply
    end
  end

  # Helper functions for start_agent complexity reduction

  defp build_spec_metadata(agent_spec) do
    %{
      module: agent_spec.module,
      args: agent_spec.args,
      restart_strategy: Map.get(agent_spec, :restart_strategy, :temporary),
      metadata: Map.get(agent_spec, :metadata, %{}),
      created_at: System.system_time(:millisecond)
    }
  end

  defp handle_successful_spec_registration(agent_id, agent_spec, spec_metadata) do
    case verify_spec_registration(agent_id) do
      :ok ->
        start_agent_process(agent_id, agent_spec, spec_metadata)

      {:error, :spec_not_visible} ->
        unregister_agent_spec(agent_id)

        Logger.error(
          "Aborting agent start for #{agent_id}: spec not visible in registry after registration."
        )

        {:error, :spec_not_visible}
    end
  end

  defp start_agent_process(agent_id, agent_spec, spec_metadata) do
    child_spec = %{
      id: agent_id,
      start:
        {agent_spec.module, :start_link, [enhance_args(agent_spec.args, agent_id, spec_metadata)]},
      restart: spec_metadata.restart_strategy,
      type: :worker
    }

    case DynamicSupervisor.start_child(@supervisor_name, child_spec) do
      {:ok, pid} ->
        Logger.info(
          "Started agent #{agent_id} on #{node(pid)} (PID: #{inspect(pid)}), awaiting registration."
        )

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("Agent already running during start_agent call",
          agent_id: agent_id,
          pid: inspect(pid)
        )

        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Helper functions for agent registration complexity reduction

  defp validate_process_alive(pid, agent_id) do
    if Process.alive?(pid) do
      :ok
    else
      Logger.warning("Attempted to register a non-alive process",
        agent_id: agent_id,
        pid: inspect(pid)
      )

      {:reply, {:error, :process_not_alive}, %{}}
    end
  end

  defp handle_agent_registration(pid, agent_id, agent_specific_metadata, state) do
    case lookup_agent_spec(agent_id) do
      {:ok, spec_metadata} ->
        full_metadata = build_full_metadata(spec_metadata, agent_specific_metadata)
        attempt_agent_registration(pid, agent_id, full_metadata, spec_metadata, state)

      {:error, :not_found} ->
        Logger.error("Could not find spec for agent #{agent_id} during registration.")
        {:reply, {:error, :spec_not_found}, state}
    end
  end

  defp build_full_metadata(spec_metadata, agent_specific_metadata) do
    runtime_metadata = %{
      module: spec_metadata.module,
      restart_strategy: spec_metadata.restart_strategy,
      started_at: System.system_time(:millisecond)
    }

    spec_metadata.metadata
    |> Map.merge(agent_specific_metadata)
    |> Map.merge(runtime_metadata)
  end

  defp attempt_agent_registration(pid, agent_id, full_metadata, spec_metadata, state) do
    case HordeRegistry.register_agent_name(agent_id, pid, full_metadata) do
      {:ok, ^pid} ->
        reply_with_registration_success(
          pid,
          agent_id,
          spec_metadata,
          state,
          "Agent registered in runtime registry"
        )

      {:error, :name_taken} ->
        handle_name_taken_scenario(pid, agent_id, full_metadata, spec_metadata, state)

      error ->
        {:reply, error, state}
    end
  end

  defp handle_name_taken_scenario(pid, agent_id, full_metadata, spec_metadata, state) do
    case HordeRegistry.lookup_agent_name_raw(agent_id) do
      {:ok, ^pid, _} ->
        # Already registered to the same PID - idempotent
        Logger.debug("Agent already registered with correct PID", agent_id: agent_id)
        {:reply, {:ok, pid}, state}

      {:ok, existing_pid, _} ->
        handle_existing_pid_conflict(
          pid,
          agent_id,
          existing_pid,
          full_metadata,
          spec_metadata,
          state
        )

      {:error, :not_registered} ->
        handle_race_condition_retry(pid, agent_id, full_metadata, spec_metadata, state)
    end
  end

  defp handle_existing_pid_conflict(
         pid,
         agent_id,
         existing_pid,
         full_metadata,
         spec_metadata,
         state
       ) do
    if Process.alive?(existing_pid) do
      Logger.error("Agent name already taken by another process",
        agent_id: agent_id,
        existing_pid: inspect(existing_pid),
        new_pid: inspect(pid)
      )

      {:reply, {:error, :name_taken}, state}
    else
      handle_stale_registration_cleanup(
        pid,
        agent_id,
        existing_pid,
        full_metadata,
        spec_metadata,
        state
      )
    end
  end

  defp handle_stale_registration_cleanup(
         pid,
         agent_id,
         existing_pid,
         full_metadata,
         spec_metadata,
         state
       ) do
    Logger.info(
      "Found stale registration for agent #{agent_id} with dead PID #{inspect(existing_pid)}. Cleaning up."
    )

    HordeRegistry.unregister_agent_name(agent_id)

    case HordeRegistry.register_agent_name(agent_id, pid, full_metadata) do
      {:ok, ^pid} ->
        reply_with_registration_success(
          pid,
          agent_id,
          spec_metadata,
          state,
          "Agent registered after cleaning stale entry"
        )

      {:error, :name_taken} ->
        Logger.error(
          "Failed to register agent #{agent_id} due to race condition after cleaning stale entry."
        )

        {:reply, {:error, :name_taken}, state}

      error ->
        {:reply, error, state}
    end
  end

  defp handle_race_condition_retry(pid, agent_id, full_metadata, spec_metadata, state) do
    case HordeRegistry.register_agent_name(agent_id, pid, full_metadata) do
      {:ok, ^pid} ->
        reply_with_registration_success(
          pid,
          agent_id,
          spec_metadata,
          state,
          "Agent registered after race condition resolution"
        )

      {:error, :name_taken} ->
        Logger.error(
          "Failed to register agent #{agent_id} due to race condition (name taken again)."
        )

        {:reply, {:error, :name_taken}, state}

      error ->
        {:reply, error, state}
    end
  end

  # Helper functions for restore_agent complexity reduction

  defp capture_agent_state(agent_id) do
    case HordeRegistry.lookup_agent_name(agent_id) do
      {:ok, pid, _metadata} ->
        try do
          GenServer.call(pid, :prepare_checkpoint, 5000)
        rescue
          # Agent may not support this call, which is fine.
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp perform_soft_stop(agent_id) do
    case HordeRegistry.lookup_agent_name(agent_id) do
      {:ok, pid, _metadata} ->
        wait_for_agent_termination(agent_id, pid)

      _ ->
        # Agent not running, proceed with restore
        :ok
    end
  end

  defp wait_for_agent_termination(agent_id, pid) do
    ref = Process.monitor(pid)
    HordeRegistry.unregister_agent_name(agent_id)
    Horde.DynamicSupervisor.terminate_child(@supervisor_name, pid)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    after
      5000 ->
        Logger.warning(
          "Timeout waiting for agent #{agent_id} (PID: #{inspect(pid)}) to terminate during restore. Aborting restore."
        )

        Process.demonitor(ref, [:flush])
        {:error, :terminate_timeout}
    end
  end

  defp perform_agent_restart(agent_id, spec_metadata, current_state) do
    {enhanced_args, recovery_status} = prepare_restart_args(spec_metadata, current_state)

    agent_spec = %{
      id: agent_id,
      module: spec_metadata.module,
      args: enhanced_args,
      restart_strategy: spec_metadata.restart_strategy,
      metadata: spec_metadata.metadata
    }

    case start_agent(agent_spec) do
      {:ok, pid} ->
        Logger.info("Restored agent #{agent_id} with recovery status: #{recovery_status}")
        {:ok, {pid, recovery_status}}

      error ->
        error
    end
  end

  defp prepare_restart_args(spec_metadata, current_state) do
    case current_state do
      nil ->
        {spec_metadata.args, :fresh_start}

      state_data ->
        {Keyword.put(spec_metadata.args, :recovered_state, state_data), :state_restored}
    end
  end

  # Helper functions for handle_agent_handoff complexity reduction

  defp perform_state_handoff(agent_id) do
    case HordeRegistry.lookup_agent_name(agent_id) do
      {:ok, pid, _metadata} ->
        extract_agent_state_safely(pid)

      _ ->
        {:error, :agent_not_found}
    end
  end

  defp extract_agent_state_safely(pid) do
    case GenServer.call(pid, :extract_state, 5000) do
      {:ok, extracted} when is_map(extracted) ->
        {:ok, extracted}

      extracted when is_map(extracted) ->
        # fallback for direct map returns
        {:ok, extracted}

      _ ->
        {:ok, %{}}
    end
  catch
    _, _ -> {:ok, %{}}
  end

  defp perform_state_takeover(agent_id, state_data) do
    case HordeRegistry.lookup_agent_name(agent_id) do
      {:ok, pid, _metadata} ->
        restore_agent_state_safely(pid, state_data)

      _ ->
        {:error, :agent_not_found}
    end
  end

  defp restore_agent_state_safely(pid, state_data) do
    GenServer.call(pid, {:restore_state, state_data}, 5000)
  catch
    _, _ -> :ok
  end

  defp reply_with_registration_success(pid, agent_id, spec_metadata, state, log_message) do
    Logger.debug(log_message,
      agent_id: agent_id,
      pid: inspect(pid)
    )

    # Broadcast agent start event
    ClusterEvents.broadcast(:agent_started, %{
      agent_id: agent_id,
      pid: pid,
      node: node(pid),
      module: spec_metadata.module,
      restart_strategy: spec_metadata.restart_strategy
    })

    {:reply, {:ok, pid}, state}
  end

  # Private functions for spec management

  defp register_agent_spec(agent_id, spec_metadata) do
    spec_key = {:agent_spec, agent_id}

    Logger.debug("Registering agent spec", agent_id: agent_id, spec_key: inspect(spec_key))

    case Horde.Registry.register(@registry_name, spec_key, spec_metadata) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, _}} ->
        # Check if the agent is already running before allowing update
        case HordeRegistry.lookup_agent_name(agent_id) do
          {:ok, _pid, _metadata} ->
            # Agent is already running, return error
            Logger.debug("Agent already running, rejecting duplicate start",
              agent_id: agent_id
            )

            {:error, :already_started}

          {:error, :not_registered} ->
            # Agent spec exists but agent not running - allow update for reconciler
            Horde.Registry.unregister(@registry_name, spec_key)

            case Horde.Registry.register(@registry_name, spec_key, spec_metadata) do
              {:ok, _} ->
                :ok

              {:error, reason} ->
                Logger.error("Failed to re-register agent spec during update",
                  agent_id: agent_id,
                  reason: reason
                )

                {:error, reason}
            end
        end
    end
  end

  defp unregister_agent_spec(agent_id) do
    spec_key = {:agent_spec, agent_id}
    Horde.Registry.unregister(@registry_name, spec_key)
    :ok
  end

  defp list_all_agent_specs do
    pattern = {{:agent_spec, :"$1"}, :"$2", :"$3"}
    guard = []
    body = [{{:"$1", :"$3"}}]

    specs = Horde.Registry.select(@registry_name, [{pattern, guard, body}])
    {:ok, specs}
  rescue
    # This broad rescue is necessary because Horde.Registry.select can raise
    # various (and undocumented) exceptions if the underlying Horde processes
    # are unavailable or if there's a CRDT sync issue. We catch the exception,
    # log it for debugging, and return an error tuple for graceful handling.
    exception ->
      Logger.error(
        "Failed to retrieve agent specs from Horde.Registry. This may indicate a cluster health issue.",
        exception: inspect(exception),
        stacktrace: __STACKTRACE__
      )

      {:error, exception}
  end

  defp enhance_args(args, agent_id, spec_metadata) do
    # Add agent identity to args so agents can conditionally self-register
    # when restarted by Horde or reconciler (not on initial start)
    enhanced_args =
      args
      |> Keyword.put(:agent_id, agent_id)
      |> Keyword.put(:agent_metadata, spec_metadata)

    enhanced_args
  end

  defp find_agent_id_by_pid(pid) do
    case list_all_agent_specs() do
      {:ok, specs} ->
        Enum.find_value(specs, {:error, :not_found}, fn {agent_id, _spec} ->
          case HordeRegistry.lookup_agent_name(agent_id) do
            {:ok, ^pid, _metadata} -> {:ok, agent_id}
            _ -> nil
          end
        end)

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  # Verifies that an agent's spec is visible in the registry after registration.
  # This polls with exponential backoff to account for CRDT sync delays.
  defp verify_spec_registration(agent_id, retries \\ 10, backoff \\ 50) do
    case lookup_agent_spec(agent_id) do
      {:ok, _spec} ->
        :ok

      {:error, :not_found} when retries > 0 ->
        Process.sleep(backoff)
        verify_spec_registration(agent_id, retries - 1, backoff * 2)

      {:error, :not_found} ->
        Logger.error(
          "Spec for agent #{agent_id} not visible in registry after multiple retries. This may indicate a CRDT sync issue."
        )

        {:error, :spec_not_visible}
    end
  end

  # Supervisor management functions

  # Get appropriate distribution strategy based on environment
  defp get_distribution_strategy do
    # Use configuration to determine strategy
    case Application.get_env(:arbor_core, :horde_distribution_strategy, :uniform_random) do
      :uniform ->
        # Use UniformDistribution for testing which works better with single nodes
        Horde.UniformDistribution

      :uniform_random ->
        # Use UniformRandomDistribution for production for better load balancing
        Horde.UniformRandomDistribution

      _ ->
        # Default to UniformRandomDistribution
        Horde.UniformRandomDistribution
    end
  end

  @doc """
  Start the Horde supervisor infrastructure.
  """
  @spec start_supervisor() :: {:ok, pid()} | {:error, term()}
  def start_supervisor do
    # Get configurable CRDT sync interval with fallback to safe default
    horde_config = Application.get_env(:arbor_core, :horde_timing, [])
    sync_interval = Keyword.get(horde_config, :sync_interval, 100)

    children = [
      {Horde.Registry,
       [
         name: @registry_name,
         keys: :unique,
         members: :auto,
         delta_crdt_options: [sync_interval: sync_interval]
       ]},
      {Horde.Registry,
       [
         name: @checkpoint_registry_name,
         keys: :unique,
         members: :auto,
         delta_crdt_options: [sync_interval: sync_interval]
       ]},
      # Anchor process for checkpoint storage
      Supervisor.child_spec({Arbor.Core.HordeCheckpointRegistry, []}, id: :checkpoint_anchor),
      {Horde.DynamicSupervisor,
       [
         name: @supervisor_name,
         strategy: :one_for_one,
         distribution_strategy: get_distribution_strategy(),
         process_redistribution: :active,
         members: :auto,
         delta_crdt_options: [sync_interval: sync_interval]
       ]},
      # Central registration handler
      {Arbor.Core.HordeSupervisor, []}
      # Note: AgentReconciler disabled for basic testing
      # TODO: Re-enable when Highlander dependency issue is resolved
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: Arbor.Core.HordeSupervisorSupervisor
    )
  end

  @doc """
  Join a node to the supervisor cluster.
  """
  @spec join_supervisor(node()) :: :ok
  def join_supervisor(node) do
    Horde.Cluster.set_members(@supervisor_name, [node() | [node]])
    Horde.Cluster.set_members(@registry_name, [node() | [node]])
    Horde.Cluster.set_members(@checkpoint_registry_name, [node() | [node]])
    :ok
  end

  @doc """
  Remove a node from the supervisor cluster.
  """
  @spec leave_supervisor(node()) :: :ok
  def leave_supervisor(node) do
    current_supervisor_members = Horde.Cluster.members(@supervisor_name)
    current_registry_members = Horde.Cluster.members(@registry_name)
    current_checkpoint_registry_members = Horde.Cluster.members(@checkpoint_registry_name)

    new_supervisor_members = List.delete(current_supervisor_members, node)
    new_registry_members = List.delete(current_registry_members, node)
    new_checkpoint_registry_members = List.delete(current_checkpoint_registry_members, node)

    Horde.Cluster.set_members(@supervisor_name, new_supervisor_members)
    Horde.Cluster.set_members(@registry_name, new_registry_members)
    Horde.Cluster.set_members(@checkpoint_registry_name, new_checkpoint_registry_members)
    :ok
  end
end
