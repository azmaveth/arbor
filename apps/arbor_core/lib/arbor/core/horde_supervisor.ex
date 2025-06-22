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
  # SupervisorContract Implementation
  # ================================

  @impl SupervisorContract
  def start_agent(agent_spec) do
    agent_id = agent_spec.id

    # 1. Store the agent spec persistently FIRST
    spec_metadata = %{
      module: agent_spec.module,
      args: agent_spec.args,
      restart_strategy: Map.get(agent_spec, :restart_strategy, :temporary),
      metadata: Map.get(agent_spec, :metadata, %{}),
      created_at: System.system_time(:millisecond)
    }

    # Register the spec in a way that persists beyond process death
    case register_agent_spec(agent_id, spec_metadata) do
      :ok ->
        # Synchronously verify that the spec is readable before starting the agent
        # to prevent a race condition where the agent starts before its spec is
        # visible in the CRDT.
        case verify_spec_registration(agent_id) do
          :ok ->
            # 2. Start the actual process via Horde
            child_spec = %{
              id: agent_id,
              start:
                {agent_spec.module, :start_link,
                 [enhance_args(agent_spec.args, agent_id, spec_metadata)]},
              # Respect the agent's restart strategy
              restart: spec_metadata.restart_strategy,
              type: :worker
            }

            case DynamicSupervisor.start_child(@supervisor_name, child_spec) do
              {:ok, pid} ->
                Logger.info(
                  "Started agent #{agent_id} on #{node(pid)} (PID: #{inspect(pid)}), awaiting registration."
                )

                # The agent will now call back to register itself.
                {:ok, pid}

              {:error, {:already_started, pid}} ->
                # Agent already started. It should have registered itself or will do so.
                # The reconciler will handle any inconsistencies.
                Logger.debug("Agent already running during start_agent call",
                  agent_id: agent_id,
                  pid: inspect(pid)
                )

                {:ok, pid}

              {:error, reason} ->
                # Let AgentReconciler handle cleanup of failed specs to avoid
                # conflicts with Horde's transient restart strategy
                {:error, reason}
            end

          {:error, :spec_not_visible} ->
            # If the spec isn't visible, starting the agent will fail.
            # Clean up the spec we attempted to register to avoid orphans.
            unregister_agent_spec(agent_id)

            Logger.error(
              "Aborting agent start for #{agent_id}: spec not visible in registry after registration."
            )

            {:error, :spec_not_visible}
        end

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
              node: node(pid)
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
        # Attempt to capture state before stopping
        current_state =
          case HordeRegistry.lookup_agent_name(agent_id) do
            {:ok, pid, _metadata} ->
              # Ask the agent to prepare its state for checkpointing.
              try do
                GenServer.call(pid, :prepare_checkpoint, 5000)
              rescue
                # Agent may not support this call, which is fine.
                _ -> nil
              end

            _ ->
              nil
          end

        # Perform a "soft stop" if the agent is running (don't delete spec or checkpoint)
        termination_result =
          case HordeRegistry.lookup_agent_name(agent_id) do
            {:ok, pid, _metadata} ->
              ref = Process.monitor(pid)
              HordeRegistry.unregister_agent_name(agent_id)
              Horde.DynamicSupervisor.terminate_child(@supervisor_name, pid)

              # Reliably wait for the process to terminate to avoid race conditions
              receive do
                {:DOWN, ^ref, :process, _pid, _reason} ->
                  :ok

                  # Process terminated successfully
              after
                5000 ->
                  # The process did not terminate in time, abort restore
                  Logger.warning(
                    "Timeout waiting for agent #{agent_id} (PID: #{inspect(pid)}) to terminate during restore. Aborting restore."
                  )

                  Process.demonitor(ref, [:flush])
                  {:error, :terminate_timeout}
              end

            _ ->
              # Agent not running, proceed with restore
              :ok
          end

        case termination_result do
          :ok ->
            # Prepare args with recovery data if available and determine recovery status
            {enhanced_args, recovery_status} =
              case current_state do
                nil ->
                  {spec_metadata.args, :fresh_start}

                state_data ->
                  {Keyword.put(spec_metadata.args, :recovered_state, state_data), :state_restored}
              end

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

          {:error, :terminate_timeout} ->
            # Propagate the error. The agent is in a zombie state (unregistered but possibly alive).
            # The reconciler will eventually handle this.
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

  @impl SupervisorContract
  def handle_agent_handoff(agent_id, operation, state_data) do
    case operation do
      :handoff ->
        # Try to extract state from running agent
        case HordeRegistry.lookup_agent_name(agent_id) do
          {:ok, pid, _metadata} ->
            try do
              case GenServer.call(pid, :extract_state, 5000) do
                extracted when is_map(extracted) -> {:ok, extracted}
                _ -> {:ok, %{}}
              end
            catch
              _, _ -> {:ok, %{}}
            end

          _ ->
            {:error, :agent_not_found}
        end

      :takeover ->
        case HordeRegistry.lookup_agent_name(agent_id) do
          {:ok, pid, _metadata} ->
            try do
              GenServer.call(pid, {:restore_state, state_data}, 5000)
            catch
              _, _ -> :ok
            end

          _ ->
            {:error, :agent_not_found}
        end
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

    case Horde.Registry.lookup(@registry_name, spec_key) do
      [] -> {:error, :not_found}
      [{_owner_pid, spec_metadata}] -> {:ok, spec_metadata}
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

  @spec extract_agent_state(String.t(), any()) :: {:ok, any()} | {:error, term()}
  def extract_agent_state(agent_id, _state \\ nil) do
    handle_agent_handoff(agent_id, :handoff, nil)
  end

  @spec restore_agent_state(String.t(), any(), any()) :: {:ok, any()} | {:error, term()}
  def restore_agent_state(agent_id, state_data, _state \\ nil) do
    handle_agent_handoff(agent_id, :takeover, state_data)
  end

  # ================================
  # GenServer Callbacks
  # ================================

  @impl GenServer
  def init(_opts) do
    # Stateless
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:register_agent, pid, agent_id, agent_specific_metadata}, _from, state) do
    if Process.alive?(pid) do
      case lookup_agent_spec(agent_id) do
        {:ok, spec_metadata} ->
          # Merge all metadata sources
          runtime_metadata = %{
            module: spec_metadata.module,
            restart_strategy: spec_metadata.restart_strategy,
            started_at: System.system_time(:millisecond)
          }

          full_metadata =
            spec_metadata.metadata
            |> Map.merge(agent_specific_metadata)
            |> Map.merge(runtime_metadata)

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
              # Idempotency check: if already registered to the same pid, it's ok.
              # Also handle stale registrations where the old PID is dead.
              case HordeRegistry.lookup_agent_name_raw(agent_id) do
                {:ok, ^pid, _} ->
                  # Case 1: Already registered to the same PID. This is idempotent.
                  Logger.debug("Agent already registered with correct PID", agent_id: agent_id)
                  {:reply, {:ok, pid}, state}

                {:ok, existing_pid, _} ->
                  # Case 2: Registered to a different PID.
                  if Process.alive?(existing_pid) do
                    # The existing PID is alive, so the name is genuinely taken.
                    Logger.error("Agent name already taken by another process",
                      agent_id: agent_id,
                      existing_pid: inspect(existing_pid),
                      new_pid: inspect(pid)
                    )

                    {:reply, {:error, :name_taken}, state}
                  else
                    # The existing PID is dead. This is a stale registration.
                    # Unregister the dead one and try registering the new one.
                    Logger.info(
                      "Found stale registration for agent #{agent_id} with dead PID #{inspect(existing_pid)}. Cleaning up."
                    )

                    HordeRegistry.unregister_agent_name(agent_id)

                    # Re-attempt registration. This could still fail due to a race condition.
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

                {:error, :not_registered} ->
                  # Race condition: The name was taken, but now it's free.
                  # We can safely try to register again.
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

            error ->
              {:reply, error, state}
          end

        {:error, :not_found} ->
          Logger.error("Could not find spec for agent #{agent_id} during registration.")
          {:reply, {:error, :spec_not_found}, state}
      end
    else
      Logger.warning("Attempted to register a non-alive process",
        agent_id: agent_id,
        pid: inspect(pid)
      )

      {:reply, {:error, :process_not_alive}, state}
    end
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

    case Horde.Registry.register(@registry_name, spec_key, spec_metadata) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, _}} ->
        # Update existing spec
        Horde.Registry.unregister(@registry_name, spec_key)

        case Horde.Registry.register(@registry_name, spec_key, spec_metadata) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
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

  @doc """
  Verifies that an agent's spec is visible in the registry after registration.
  This polls with exponential backoff to account for CRDT sync delays.
  """
  defp verify_spec_registration(agent_id, retries \\ 5, backoff \\ 20) do
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

  @doc """
  Start the Horde supervisor infrastructure.
  """
  @spec start_supervisor() :: {:ok, pid()} | {:error, term()}
  def start_supervisor do
    children = [
      {Horde.Registry,
       [
         name: @registry_name,
         keys: :unique,
         members: :auto,
         delta_crdt_options: [sync_interval: 100]
       ]},
      {Horde.DynamicSupervisor,
       [
         name: @supervisor_name,
         strategy: :one_for_one,
         distribution_strategy: Horde.UniformRandomDistribution,
         process_redistribution: :active,
         members: :auto,
         delta_crdt_options: [sync_interval: 100]
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
    :ok
  end

  @doc """
  Remove a node from the supervisor cluster.
  """
  @spec leave_supervisor(node()) :: :ok
  def leave_supervisor(node) do
    current_supervisor_members = Horde.Cluster.members(@supervisor_name)
    current_registry_members = Horde.Cluster.members(@registry_name)

    new_supervisor_members = List.delete(current_supervisor_members, node)
    new_registry_members = List.delete(current_registry_members, node)

    Horde.Cluster.set_members(@supervisor_name, new_supervisor_members)
    Horde.Cluster.set_members(@registry_name, new_registry_members)
    :ok
  end
end
