defmodule Arbor.Core.AgentReconciler do
  @moduledoc """
  Periodically reconciles agent specs stored in the registry with running processes.

  This process ensures that:
  - Agents specified in the registry are actually running
  - Orphaned processes (running but not in registry) are cleaned up
  - Failed agents are restarted according to their restart strategy

  This provides self-healing capabilities for the distributed agent system.
  """

  use GenServer
  require Logger

  alias Arbor.Core.{AgentCheckpoint, ClusterEvents, HordeRegistry, TelemetryHelper}
  alias DynamicSupervisor

  @behaviour Arbor.Contracts.Agent.Reconciler

  # Configuration
  @registry_name Arbor.Core.HordeAgentRegistry
  @supervisor_name Arbor.Core.HordeAgentSupervisor
  # 30 seconds default
  @reconcile_interval Application.compile_env(:arbor_core, :reconciler_interval, 30_000)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # Schedule initial reconciliation
    schedule_reconciliation()

    state = %{
      last_reconcile: nil,
      reconcile_count: 0,
      errors: []
    }

    Logger.info("AgentReconciler started")
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:reconcile, state) do
    Logger.debug("Starting agent reconciliation")

    # Skip if already reconciling
    case Map.get(state, :reconciling, false) do
      true ->
        Logger.debug("Skipping reconciliation - already in progress")
        schedule_reconciliation()
        {:noreply, state}

      false ->
        start_time = System.monotonic_time()
        new_state = Map.put(state, :reconciling, true)

        try do
          do_reconcile_agents()

          duration_ms =
            System.convert_time_unit(
              System.monotonic_time() - start_time,
              :native,
              :millisecond
            )

          Logger.debug("Agent reconciliation completed", duration_ms: duration_ms)

          final_state = %{
            new_state
            | last_reconcile: System.system_time(:millisecond),
              reconcile_count: state.reconcile_count + 1,
              errors: [],
              reconciling: false
          }

          schedule_reconciliation()
          {:noreply, final_state}
        rescue
          error ->
            Logger.error("Agent reconciliation failed", error: inspect(error))

            final_state = %{
              new_state
              | # Keep last 10 errors
                errors: [error | Enum.take(state.errors, 9)],
                reconciling: false
            }

            schedule_reconciliation()
            {:noreply, final_state}
        end
    end
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status = %{
      last_reconcile: state.last_reconcile,
      reconcile_count: state.reconcile_count,
      recent_errors: state.errors
    }

    {:reply, status, state}
  end

  @impl GenServer
  def handle_call(:force_reconcile, _from, state) do
    # Prevent overlapping reconciliation cycles
    case Map.get(state, :reconciling, false) do
      true ->
        # Already reconciling, skip this call
        {:reply, :already_running, state}

      false ->
        new_state = Map.put(state, :reconciling, true)

        try do
          do_reconcile_agents()

          # Update state to reflect the forced reconciliation
          final_state = %{
            new_state
            | last_reconcile: System.system_time(:millisecond),
              reconcile_count: state.reconcile_count + 1,
              errors: [],
              reconciling: false
          }

          {:reply, :ok, final_state}
        rescue
          error ->
            # Add error to state and clear reconciling flag
            final_state = %{
              new_state
              | # Keep last 10 errors
                errors: [error | Enum.take(state.errors, 9)],
                reconciling: false
            }

            {:reply, {:error, error}, final_state}
        end
    end
  end

  # Public API

  @doc """
  Get reconciler status information.
  """
  @spec get_status() :: map()
  def get_status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Force an immediate reconciliation cycle.
  """
  @spec force_reconcile() :: :ok | {:error, any()}
  def force_reconcile do
    GenServer.call(__MODULE__, :force_reconcile, 30_000)
  end

  #
  # Arbor.Contracts.Agent.Reconciler callbacks
  #

  @impl Arbor.Contracts.Agent.Reconciler
  def reconcile_agents do
    try do
      do_reconcile_agents()
      :ok
    rescue
      error -> {:error, {error, __STACKTRACE__}}
    end
  end

  @impl Arbor.Contracts.Agent.Reconciler
  def find_missing_agents do
    agent_specs = get_all_agent_specs()
    running_children = get_running_children()

    {_undefined_children, identified_children} =
      Enum.split_with(running_children, fn
        {:undefined, _pid} -> true
        _ -> false
      end)

    spec_ids = MapSet.new(agent_specs, fn {agent_id, _spec} -> agent_id end)
    running_ids = MapSet.new(identified_children, fn {agent_id, _pid} -> agent_id end)

    missing_agent_ids = MapSet.difference(spec_ids, running_ids)

    Enum.map(missing_agent_ids, fn agent_id ->
      {^agent_id, spec_metadata} = List.keyfind(agent_specs, agent_id, 0)
      Map.put(spec_metadata, :id, agent_id)
    end)
  end

  @impl Arbor.Contracts.Agent.Reconciler
  def cleanup_orphaned_processes do
    agent_specs = get_all_agent_specs()
    running_children = get_running_children()

    {undefined_children, identified_children} =
      Enum.split_with(running_children, fn
        {:undefined, _pid} -> true
        _ -> false
      end)

    spec_ids = MapSet.new(agent_specs, fn {agent_id, _spec} -> agent_id end)
    running_ids = MapSet.new(identified_children, fn {agent_id, _pid} -> agent_id end)

    orphaned_agent_ids = MapSet.difference(running_ids, spec_ids)

    # Clean up undefined children
    for {:undefined, pid} <- undefined_children do
      cleanup_orphaned_agent(:undefined, pid)
    end

    # Clean up identified orphans
    for agent_id <- orphaned_agent_ids do
      case List.keyfind(identified_children, agent_id, 0) do
        {^agent_id, pid} -> cleanup_orphaned_agent(agent_id, pid)
        nil -> :ok
      end
    end

    :ok
  end

  @impl Arbor.Contracts.Agent.Reconciler
  def restart_agent(agent_spec, reason) do
    Logger.info("Restarting agent via contract",
      agent_id: agent_spec.id,
      reason: inspect(reason)
    )

    agent_id = agent_spec.id
    spec_metadata = Map.delete(agent_spec, :id)
    restart_missing_agent(agent_id, spec_metadata)
  end

  # Private functions

  defp schedule_reconciliation do
    Process.send_after(self(), :reconcile, @reconcile_interval)
  end

  defp do_reconcile_agents do
    start_time = System.monotonic_time(:millisecond)
    node_name = node()

    # Emit start telemetry and broadcast event
    emit_reconciliation_start(start_time, node_name)

    # Gather data about agents and processes
    {agent_specs, spec_lookup_duration} = time_operation(fn -> get_all_agent_specs() end)

    {running_children, supervisor_lookup_duration} =
      time_operation(fn -> get_running_children() end)

    # Emit lookup performance metrics
    emit_lookup_performance_metrics(
      spec_lookup_duration,
      supervisor_lookup_duration,
      length(agent_specs),
      length(running_children),
      node_name
    )

    # Analyze agent state discrepancies
    analysis = analyze_agent_discrepancies(agent_specs, running_children)

    # Emit discovery metrics
    emit_discovery_metrics(analysis, node_name)

    # Process missing agents (restart them with atomic cleanup)
    {missing_restarted, restart_errors} =
      process_missing_agents(
        analysis.missing_agents,
        agent_specs,
        node_name
      )

    # Process undefined children (cleanup)
    {undefined_cleaned, undefined_errors} =
      process_undefined_children(
        analysis.undefined_children,
        node_name
      )

    # Process orphaned agents (cleanup)
    {orphaned_cleaned, cleanup_errors} =
      process_orphaned_agents(
        analysis.orphaned_agents,
        analysis.identified_children,
        node_name
      )

    # Combine cleanup errors
    all_cleanup_errors = undefined_errors ++ cleanup_errors

    # Calculate total duration
    duration_ms = System.monotonic_time(:millisecond) - start_time

    # Log completion summary
    log_reconciliation_summary(%{
      specs: length(agent_specs),
      running: length(running_children),
      missing: MapSet.size(analysis.missing_agents),
      orphaned: MapSet.size(analysis.orphaned_agents),
      restarted: missing_restarted,
      cleaned: orphaned_cleaned + undefined_cleaned,
      restart_errors: length(restart_errors),
      cleanup_errors: length(all_cleanup_errors),
      duration: duration_ms
    })

    # Log errors if any
    log_reconciliation_errors(restart_errors, all_cleanup_errors, node_name)

    # Emit completion telemetry
    emit_reconciliation_complete(%{
      missing_restarted: missing_restarted,
      orphaned_cleaned: orphaned_cleaned + undefined_cleaned,
      duration_ms: duration_ms,
      analysis: analysis,
      spec_lookup_duration: spec_lookup_duration,
      supervisor_lookup_duration: supervisor_lookup_duration,
      restart_errors: restart_errors,
      cleanup_errors: all_cleanup_errors,
      node_name: node_name
    })

    # Broadcast completion event
    broadcast_reconciliation_complete(
      missing_restarted,
      orphaned_cleaned + undefined_cleaned,
      duration_ms,
      analysis,
      restart_errors,
      all_cleanup_errors
    )
  end

  # Analyze discrepancies between specs and running processes
  defp analyze_agent_discrepancies(agent_specs, running_children) do
    # Separate undefined children from properly identified ones
    {undefined_children, identified_children} =
      Enum.split_with(running_children, fn
        {:undefined, _pid} -> true
        _ -> false
      end)

    # Create lookup maps
    spec_ids = MapSet.new(agent_specs, fn {agent_id, _spec} -> agent_id end)
    running_ids = MapSet.new(identified_children, fn {agent_id, _pid} -> agent_id end)

    # Find agents that should be running but aren't
    missing_agents = MapSet.difference(spec_ids, running_ids)

    # Find running agents without specs (orphans)
    orphaned_agents = MapSet.difference(running_ids, spec_ids)

    %{
      spec_ids: spec_ids,
      running_ids: running_ids,
      missing_agents: missing_agents,
      orphaned_agents: orphaned_agents,
      undefined_children: undefined_children,
      identified_children: identified_children
    }
  end

  # Process missing agents by restarting them
  defp process_missing_agents(missing_agents, agent_specs, node_name) do
    Enum.reduce(missing_agents, {0, []}, fn agent_id, {success_count, errors} ->
      restart_start = System.monotonic_time(:millisecond)

      case List.keyfind(agent_specs, agent_id, 0) do
        {^agent_id, spec_metadata} ->
          case restart_missing_agent(agent_id, spec_metadata) do
            {:ok, _pid} ->
              restart_duration = System.monotonic_time(:millisecond) - restart_start

              emit_agent_restart_success(
                agent_id,
                spec_metadata.restart_strategy,
                restart_duration,
                node_name,
                spec_metadata.module
              )

              {success_count + 1, errors}

            {:error, reason} ->
              restart_duration = System.monotonic_time(:millisecond) - restart_start
              error = %{agent_id: agent_id, reason: reason, duration_ms: restart_duration}

              emit_agent_restart_failed(
                agent_id,
                spec_metadata.restart_strategy,
                restart_duration,
                node_name,
                spec_metadata.module
              )

              {success_count, [error | errors]}
          end

        nil ->
          error = %{agent_id: agent_id, reason: :spec_not_found}
          Logger.warning("Missing agent spec during reconciliation", agent_id: agent_id)
          emit_agent_restart_error(agent_id, node_name)
          {success_count, [error | errors]}
      end
    end)
  end

  # Process undefined children by cleaning them up
  defp process_undefined_children(undefined_children, node_name) do
    Enum.reduce(undefined_children, {0, []}, fn {:undefined, pid}, {success_count, errors} ->
      cleanup_start = System.monotonic_time(:millisecond)

      Logger.debug("Processing undefined child", pid: inspect(pid))

      case cleanup_orphaned_agent(:undefined, pid) do
        true ->
          cleanup_duration = System.monotonic_time(:millisecond) - cleanup_start
          emit_agent_cleanup_success(:undefined, pid, cleanup_duration, node_name)
          {success_count + 1, errors}

        false ->
          cleanup_duration = System.monotonic_time(:millisecond) - cleanup_start

          error = %{
            agent_id: :undefined,
            reason: :cleanup_failed,
            duration_ms: cleanup_duration
          }

          emit_agent_cleanup_failed(:undefined, pid, cleanup_duration, node_name)
          {success_count, [error | errors]}
      end
    end)
  end

  # Process orphaned agents by cleaning them up
  defp process_orphaned_agents(orphaned_agents, identified_children, node_name) do
    Enum.reduce(orphaned_agents, {0, []}, fn agent_id, {success_count, errors} ->
      cleanup_start = System.monotonic_time(:millisecond)

      Logger.debug("Processing orphaned agent", agent_id: agent_id)

      case List.keyfind(identified_children, agent_id, 0) do
        {^agent_id, pid} ->
          case cleanup_orphaned_agent(agent_id, pid) do
            true ->
              cleanup_duration = System.monotonic_time(:millisecond) - cleanup_start
              emit_agent_cleanup_success(agent_id, pid, cleanup_duration, node_name)
              {success_count + 1, errors}

            false ->
              cleanup_duration = System.monotonic_time(:millisecond) - cleanup_start

              error = %{
                agent_id: agent_id,
                reason: :cleanup_failed,
                duration_ms: cleanup_duration
              }

              emit_agent_cleanup_failed(agent_id, pid, cleanup_duration, node_name)
              {success_count, [error | errors]}
          end

        nil ->
          error = %{agent_id: agent_id, reason: :process_not_found}
          Logger.warning("Orphaned agent not found during cleanup", agent_id: agent_id)
          emit_agent_cleanup_error(agent_id, node_name)
          {success_count, [error | errors]}
      end
    end)
  end

  # Telemetry emission functions
  defp emit_reconciliation_start(start_time, node_name) do
    TelemetryHelper.emit_reconciliation_event(
      :start,
      %{start_time: start_time},
      %{node: node_name, reconciler: __MODULE__}
    )

    ClusterEvents.broadcast(:reconciliation_started, %{
      reconciler: __MODULE__
    })
  end

  defp emit_lookup_performance_metrics(
         spec_duration,
         supervisor_duration,
         spec_count,
         running_count,
         node_name
       ) do
    TelemetryHelper.emit_reconciliation_event(
      :lookup_performance,
      %{
        spec_lookup_duration_ms: spec_duration,
        supervisor_lookup_duration_ms: supervisor_duration,
        specs_found: spec_count,
        running_processes: running_count
      },
      %{node: node_name}
    )
  end

  defp emit_discovery_metrics(analysis, node_name) do
    TelemetryHelper.emit_reconciliation_event(
      :agent_discovery,
      %{
        total_specs: MapSet.size(analysis.spec_ids),
        total_running: MapSet.size(analysis.running_ids),
        missing_count: MapSet.size(analysis.missing_agents),
        orphaned_count: MapSet.size(analysis.orphaned_agents)
      },
      %{
        node: node_name,
        missing_agents: Enum.to_list(analysis.missing_agents),
        orphaned_agents: Enum.to_list(analysis.orphaned_agents)
      }
    )
  end

  defp emit_agent_restart_success(agent_id, restart_strategy, duration, node_name, module) do
    TelemetryHelper.emit_reconciliation_event(
      :agent_restart_success,
      %{duration_ms: duration},
      %{
        agent_id: agent_id,
        restart_strategy: restart_strategy,
        node: node_name,
        module: module
      }
    )
  end

  defp emit_agent_restart_failed(agent_id, restart_strategy, duration, node_name, module) do
    TelemetryHelper.emit_reconciliation_event(
      :agent_restart_failed,
      %{duration_ms: duration},
      %{
        agent_id: agent_id,
        restart_strategy: restart_strategy,
        node: node_name,
        module: module
      }
    )
  end

  defp emit_agent_restart_error(agent_id, node_name) do
    TelemetryHelper.emit_reconciliation_event(
      :agent_restart_error,
      %{},
      %{
        agent_id: agent_id,
        error: :spec_not_found,
        node: node_name
      }
    )
  end

  defp emit_agent_cleanup_success(agent_id, pid, duration, node_name) do
    TelemetryHelper.emit_reconciliation_event(
      :agent_cleanup_success,
      %{duration_ms: duration},
      %{
        agent_id: agent_id,
        pid: inspect(pid),
        node: node_name
      }
    )
  end

  defp emit_agent_cleanup_failed(agent_id, pid, duration, node_name) do
    TelemetryHelper.emit_reconciliation_event(
      :agent_cleanup_failed,
      %{duration_ms: duration},
      %{
        agent_id: agent_id,
        pid: inspect(pid),
        node: node_name
      }
    )
  end

  defp emit_agent_cleanup_error(agent_id, node_name) do
    TelemetryHelper.emit_reconciliation_event(
      :agent_cleanup_error,
      %{},
      %{
        agent_id: agent_id,
        error: :process_not_found,
        node: node_name
      }
    )
  end

  defp log_reconciliation_summary(%{
         specs: specs,
         running: running,
         missing: missing,
         orphaned: orphaned,
         restarted: restarted,
         cleaned: cleaned,
         restart_errors: restart_errors,
         cleanup_errors: cleanup_errors,
         duration: duration
       }) do
    Logger.debug("Reconciliation complete",
      specs: specs,
      running: running,
      missing: missing,
      orphaned: orphaned,
      restarted: restarted,
      cleaned: cleaned,
      restart_errors: restart_errors,
      cleanup_errors: cleanup_errors,
      duration_ms: duration
    )
  end

  defp log_reconciliation_errors(restart_errors, cleanup_errors, node_name) do
    if restart_errors != [] do
      Logger.warning("Agent restart errors during reconciliation",
        errors: restart_errors,
        node: node_name
      )
    end

    if cleanup_errors != [] do
      Logger.warning("Agent cleanup errors during reconciliation",
        errors: cleanup_errors,
        node: node_name
      )
    end
  end

  defp emit_reconciliation_complete(%{
         missing_restarted: missing_restarted,
         orphaned_cleaned: orphaned_cleaned,
         duration_ms: duration_ms,
         analysis: analysis,
         spec_lookup_duration: spec_lookup_duration,
         supervisor_lookup_duration: supervisor_lookup_duration,
         restart_errors: restart_errors,
         cleanup_errors: cleanup_errors,
         node_name: node_name
       }) do
    :telemetry.execute(
      [:arbor, :reconciliation, :complete],
      %{
        # Core metrics
        missing_agents_restarted: missing_restarted,
        orphaned_agents_cleaned: orphaned_cleaned,
        duration_ms: duration_ms,
        total_specs: MapSet.size(analysis.spec_ids),
        total_running: MapSet.size(analysis.running_ids),
        missing_count: MapSet.size(analysis.missing_agents),
        orphaned_count: MapSet.size(analysis.orphaned_agents),
        # Performance metrics
        spec_lookup_duration_ms: spec_lookup_duration,
        supervisor_lookup_duration_ms: supervisor_lookup_duration,
        # Error tracking
        restart_errors_count: length(restart_errors),
        cleanup_errors_count: length(cleanup_errors),
        # Health indicators
        reconciliation_efficiency:
          calculate_efficiency(
            missing_restarted,
            orphaned_cleaned,
            MapSet.size(analysis.missing_agents),
            MapSet.size(analysis.orphaned_agents)
          ),
        system_health_score:
          calculate_health_score(
            MapSet.size(analysis.spec_ids),
            MapSet.size(analysis.running_ids),
            length(restart_errors),
            length(cleanup_errors)
          )
      },
      %{
        node: node_name,
        reconciler: __MODULE__,
        restart_errors: restart_errors,
        cleanup_errors: cleanup_errors
      }
    )
  end

  defp broadcast_reconciliation_complete(
         missing_restarted,
         orphaned_cleaned,
         duration_ms,
         analysis,
         restart_errors,
         cleanup_errors
       ) do
    event_type =
      if length(restart_errors) > 0 or length(cleanup_errors) > 0 do
        :reconciliation_failed
      else
        :reconciliation_completed
      end

    ClusterEvents.broadcast(event_type, %{
      reconciler: __MODULE__,
      missing_agents_restarted: missing_restarted,
      orphaned_agents_cleaned: orphaned_cleaned,
      duration_ms: duration_ms,
      restart_errors_count: length(restart_errors),
      cleanup_errors_count: length(cleanup_errors),
      reconciliation_efficiency:
        calculate_efficiency(
          missing_restarted,
          orphaned_cleaned,
          MapSet.size(analysis.missing_agents),
          MapSet.size(analysis.orphaned_agents)
        )
    })
  end

  defp get_all_agent_specs do
    pattern = {{:agent_spec, :"$1"}, :"$2", :"$3"}
    guard = []
    body = [{{:"$1", :"$3"}}]

    Horde.Registry.select(@registry_name, [{pattern, guard, body}])
  end

  defp get_running_children do
    children =
      @supervisor_name
      |> DynamicSupervisor.which_children()
      |> Enum.map(fn
        {:undefined, pid, _type, _modules} ->
          Logger.debug("Found child with undefined ID", pid: inspect(pid))
          {:undefined, pid}

        {agent_id, pid, _type, _modules} ->
          {agent_id, pid}
      end)
      |> Enum.filter(fn {_agent_id, pid} -> is_pid(pid) and Process.alive?(pid) end)

    Logger.debug("Running children from supervisor",
      count: length(children),
      children: Enum.map(children, fn {id, pid} -> {id, inspect(pid)} end)
    )

    children
  end

  defp restart_missing_agent(agent_id, spec_metadata) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Restarting missing agent", agent_id: agent_id)

    # Emit telemetry for agent restart attempt with enhanced metadata
    TelemetryHelper.emit_agent_event(
      :restart_attempt,
      agent_id,
      %{start_time: start_time},
      %{
        restart_strategy: spec_metadata.restart_strategy,
        module: spec_metadata.module,
        created_at: spec_metadata.created_at
      }
    )

    # Only restart if restart strategy is not :temporary
    case spec_metadata.restart_strategy do
      :temporary ->
        Logger.debug("Skipping restart of temporary agent", agent_id: agent_id)
        # Remove the spec since temporary agents shouldn't be restarted
        unregister_agent_spec(agent_id)
        {:error, :temporary_agent_not_restarted}

      restart_strategy when restart_strategy in [:permanent, :transient] ->
        # ATOMIC CLEANUP: Clean up any stale registry entries first to prevent race conditions
        cleanup_stale_registry_entry(agent_id)

        # Check if agent is actually running after cleanup
        case HordeRegistry.lookup_agent_name(agent_id) do
          {:ok, pid, _metadata} ->
            # Agent is running and alive, skip restart
            Logger.debug("Agent found running during restart attempt after cleanup, skipping.",
              agent_id: agent_id,
              pid: inspect(pid)
            )

            {:ok, pid}

          {:error, :not_registered} ->
            # Agent not running, proceed with restart
            do_actual_restart(agent_id, spec_metadata, start_time)
        end

      _ ->
        Logger.warning("Unknown restart strategy for agent",
          agent_id: agent_id,
          restart_strategy: spec_metadata.restart_strategy
        )

        {:error, {:unknown_restart_strategy, spec_metadata.restart_strategy}}
    end
  end

  defp do_actual_restart(agent_id, spec_metadata, start_time) do
    # Agent not running, proceed with restart
    # Note: stale registry entries are cleaned up before calling this function

    # Attempt state recovery if the agent supports checkpointing
    recovery_result =
      AgentCheckpoint.attempt_state_recovery(
        spec_metadata.module,
        agent_id,
        spec_metadata.args
      )

    Logger.info("Recovery attempt for #{agent_id}: #{inspect(recovery_result)}")

    # Reconstruct the child spec and start the agent
    enhanced_args =
      spec_metadata.args
      |> Keyword.put(:agent_id, agent_id)
      |> Keyword.put(:agent_metadata, spec_metadata.metadata)
      |> maybe_add_recovery_data(recovery_result)

    child_spec = %{
      id: agent_id,
      start: {spec_metadata.module, :start_link, [enhanced_args]},
      # Always use :temporary for Horde, reconciler handles restart logic
      restart: :temporary,
      type: :worker
    }

    case DynamicSupervisor.start_child(@supervisor_name, child_spec) do
      {:ok, pid} ->
        restart_duration = System.monotonic_time(:millisecond) - start_time

        # Note: Agents using AgentBehavior will register themselves in handle_continue(:register_with_supervisor)
        # We don't need to register them here, as that would cause a race condition.
        # Only log the successful restart.

        Logger.info("Successfully restarted missing agent",
          agent_id: agent_id,
          pid: inspect(pid),
          duration_ms: restart_duration
        )

        TelemetryHelper.emit_agent_event(
          :restarted,
          agent_id,
          %{
            restart_duration_ms: restart_duration,
            memory_usage: get_process_memory(pid)
          },
          %{
            pid: inspect(pid),
            module: spec_metadata.module,
            restart_strategy: spec_metadata.restart_strategy
          }
        )

        # Broadcast agent restart event
        ClusterEvents.broadcast(:agent_restarted, %{
          agent_id: agent_id,
          pid: pid,
          module: spec_metadata.module,
          restart_strategy: spec_metadata.restart_strategy,
          restart_duration_ms: restart_duration,
          memory_usage: get_process_memory(pid)
        })

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Agent already started, ensure it's registered
        runtime_metadata = %{
          module: spec_metadata.module,
          restart_strategy: spec_metadata.restart_strategy,
          started_at: System.system_time(:millisecond)
        }

        case HordeRegistry.register_agent_name(agent_id, pid, runtime_metadata) do
          {:ok, ^pid} ->
            Logger.debug("Already running agent registered in runtime registry",
              agent_id: agent_id,
              pid: inspect(pid)
            )

          {:error, :name_taken} ->
            Logger.debug("Agent already registered",
              agent_id: agent_id,
              pid: inspect(pid)
            )

          {:error, reason} ->
            Logger.warning("Failed to register already running agent",
              agent_id: agent_id,
              pid: inspect(pid),
              reason: inspect(reason)
            )
        end

        Logger.debug("Agent already running during restart",
          agent_id: agent_id,
          pid: inspect(pid)
        )

        {:ok, pid}

      {:error, reason} ->
        restart_duration = System.monotonic_time(:millisecond) - start_time

        Logger.error("Failed to restart missing agent",
          agent_id: agent_id,
          reason: inspect(reason),
          duration_ms: restart_duration
        )

        TelemetryHelper.emit_agent_event(
          :restart_failed,
          agent_id,
          %{
            restart_duration_ms: restart_duration,
            error_category: classify_error(reason)
          },
          %{
            reason: inspect(reason),
            module: spec_metadata.module,
            restart_strategy: spec_metadata.restart_strategy
          }
        )

        # Broadcast agent failure event
        ClusterEvents.broadcast(:agent_failed, %{
          agent_id: agent_id,
          reason: inspect(reason),
          module: spec_metadata.module,
          restart_strategy: spec_metadata.restart_strategy,
          restart_duration_ms: restart_duration,
          error_category: classify_error(reason)
        })

        {:error, reason}
    end
  end

  defp cleanup_stale_registry_entry(agent_id) do
    # NOTE: Known race condition - There's a small window between checking if a process
    # is alive and unregistering it where another reconciler instance or Horde could
    # restart the agent with the same agent_id but a new PID. In this case, we might
    # inadvertently unregister the newly started agent. This is acceptable as the
    # reconciler will detect and restart it in the next cycle. A "compare-and-swap"
    # unregister operation in Horde.Registry would eliminate this race.
    case HordeRegistry.lookup_agent_name_raw(agent_id) do
      {:ok, pid, _metadata} ->
        if Process.alive?(pid) do
          # Process is alive, no cleanup needed
          true
        else
          # Process is dead, clean up stale registry entry
          Logger.debug("Cleaning up stale registry entry for dead process",
            agent_id: agent_id,
            pid: inspect(pid)
          )

          HordeRegistry.unregister_agent_name(agent_id)
          true
        end

      {:error, :not_registered} ->
        # No registry entry, nothing to clean up
        true

      {:error, reason} ->
        Logger.warning("Failed to check registry entry for cleanup",
          agent_id: agent_id,
          reason: inspect(reason)
        )

        false
    end
  end

  defp cleanup_orphaned_agent(agent_id, pid) do
    # Give undefined processes a grace period to register
    # They may have just been started and are in the process of registering
    if agent_id == :undefined do
      # For undefined processes, we use a simple heuristic:
      # Skip cleanup to give them time to register
      # The process start time is not easily available from Process.info
      # So we'll be conservative and skip cleanup for all undefined processes
      # They'll be cleaned up in the next cycle if they don't register
      Logger.debug("Skipping cleanup of undefined process to allow registration",
        pid: inspect(pid)
      )

      # Return true to indicate we handled it (by skipping)
      true
    else
      # For identified orphans, proceed with cleanup
      Logger.warning("Cleaning up orphaned agent", agent_id: agent_id, pid: inspect(pid))

      # Emit telemetry for orphaned agent cleanup
      TelemetryHelper.emit_agent_event(
        :cleanup_attempt,
        agent_id,
        %{},
        %{pid: inspect(pid)}
      )

      # Clean up runtime registry entry first (like HordeSupervisor.stop_agent does)
      # Only unregister if agent_id is not :undefined
      if agent_id != :undefined do
        HordeRegistry.unregister_agent_name(agent_id)
      end

      # Terminate the orphaned process
      case DynamicSupervisor.terminate_child(@supervisor_name, pid) do
        :ok ->
          Logger.info("Successfully cleaned up orphaned agent", agent_id: agent_id)

          TelemetryHelper.emit_agent_event(
            :cleaned_up,
            agent_id,
            %{},
            %{pid: inspect(pid)}
          )

          true

        {:error, reason} ->
          Logger.error("Failed to cleanup orphaned agent",
            agent_id: agent_id,
            reason: inspect(reason)
          )

          TelemetryHelper.emit_agent_event(
            :cleanup_failed,
            agent_id,
            %{},
            %{pid: inspect(pid), reason: inspect(reason)}
          )

          false
      end
    end
  end

  defp unregister_agent_spec(agent_id) do
    spec_key = {:agent_spec, agent_id}
    Horde.Registry.unregister(@registry_name, spec_key)
  end

  # Helper function to time operations
  defp time_operation(func) do
    start_time = System.monotonic_time(:millisecond)
    result = func.()
    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time
    {result, duration}
  end

  # Calculate reconciliation efficiency (0.0 to 1.0)
  defp calculate_efficiency(
         successful_restarts,
         successful_cleanups,
         total_missing,
         total_orphaned
       ) do
    total_work = total_missing + total_orphaned
    successful_work = successful_restarts + successful_cleanups

    if total_work == 0 do
      # Perfect efficiency when no work needed
      1.0
    else
      min(successful_work / total_work, 1.0)
    end
  end

  # Calculate system health score (0.0 to 1.0)
  defp calculate_health_score(total_specs, total_running, restart_errors, cleanup_errors) do
    total_errors = restart_errors + cleanup_errors
    total_agents = max(total_specs, total_running)

    cond do
      # Perfect health with no agents
      total_agents == 0 ->
        1.0

      # Perfect sync, no errors
      total_specs == total_running and total_errors == 0 ->
        1.0

      # More errors than agents (critical)
      total_errors > total_agents ->
        0.0

      true ->
        # Health score based on alignment and error rate
        alignment_score =
          if total_specs == 0,
            do: 0.0,
            else: min(total_running, total_specs) / max(total_specs, total_running)

        error_penalty = total_errors / max(total_agents, 1)
        max(0.0, alignment_score - error_penalty)
    end
  end

  # Get process memory usage safely
  defp get_process_memory(pid) do
    try do
      case Process.info(pid, :memory) do
        {:memory, memory} -> memory
        nil -> 0
      end
    rescue
      _ -> 0
    end
  end

  # Classify errors for telemetry grouping
  defp classify_error(reason) do
    case reason do
      {:already_started, _} -> :already_running
      :max_children -> :capacity_limit
      {:shutdown, _} -> :graceful_shutdown
      {:EXIT, _} -> :process_exit
      :timeout -> :startup_timeout
      :noproc -> :supervisor_unavailable
      _ -> :unknown
    end
  end

  defp maybe_add_recovery_data(args, recovery_result) do
    case recovery_result do
      {:ok, recovered_state} ->
        Logger.info("Adding recovered state to agent restart",
          agent_id: Keyword.get(args, :agent_id),
          recovered: true
        )

        Keyword.put(args, :recovered_state, recovered_state)

      {:error, :no_checkpoint} ->
        # Agent supports checkpointing but no checkpoint exists - normal startup
        args

      {:error, :not_implemented} ->
        # Agent doesn't support checkpointing - normal startup
        args

      {:error, reason} ->
        Logger.warning("State recovery failed, proceeding with normal startup",
          agent_id: Keyword.get(args, :agent_id),
          reason: inspect(reason)
        )

        args
    end
  end
end
