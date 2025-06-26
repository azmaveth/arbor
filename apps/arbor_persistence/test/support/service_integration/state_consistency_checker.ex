defmodule Arbor.Test.ServiceInteractionCase.StateConsistencyChecker do
  @moduledoc """
  Validates state consistency across distributed services.

  This module ensures that state remains consistent across Arbor's
  distributed services (Gateway, SessionManager, Registry, Supervisor)
  during integration testing. It detects state drift, orphaned resources,
  and synchronization issues.

  ## Features

  - **Cross-Service Validation**: Checks state consistency between services
  - **Resource Tracking**: Monitors resource lifecycle across services
  - **Orphan Detection**: Identifies abandoned or leaked resources
  - **State Snapshots**: Captures point-in-time state for comparison
  - **Cleanup Validation**: Ensures proper resource cleanup
  - **Consistency Rules**: Validates business logic constraints

  ## Usage

      checker = StateConsistencyChecker.start()
      
      # Validate consistency across services
      StateConsistencyChecker.validate_consistency(checker, %{
        gateway: gateway_state,
        session_manager: session_state,
        registry: registry_state
      })
      
      # Check for clean state
      StateConsistencyChecker.validate_clean_state(checker)
  """

  use GenServer

  @type service_name :: :gateway | :session_manager | :registry | :supervisor | :pubsub
  @type service_state :: map()
  @type consistency_rule :: {atom(), (map() -> boolean())}
  @type violation :: %{
          type: atom(),
          services: [service_name()],
          description: binary(),
          details: map()
        }

  defstruct state_snapshots: [],
            consistency_rules: [],
            tracked_resources: %{},
            violations: [],
            start_state: nil

  @doc """
  Starts a new state consistency checker.
  """
  @spec start() :: pid()
  def start do
    {:ok, pid} =
      GenServer.start_link(__MODULE__, %__MODULE__{
        start_state: capture_initial_state()
      })

    pid
  end

  @doc """
  Validates consistency across multiple services.
  """
  @spec validate_consistency(pid(), %{service_name() => service_state()}) ::
          :ok | {:error, [violation()]}
  def validate_consistency(checker, service_states) do
    GenServer.call(checker, {:validate_consistency, service_states})
  end

  @doc """
  Validates that system is in a clean state (no orphaned resources).
  """
  @spec validate_clean_state(pid()) :: :ok | {:error, [violation()]}
  def validate_clean_state(checker) do
    GenServer.call(checker, :validate_clean_state)
  end

  @doc """
  Takes a snapshot of current system state.
  """
  @spec take_state_snapshot(pid(), binary()) :: :ok
  def take_state_snapshot(checker, label) do
    GenServer.call(checker, {:take_state_snapshot, label})
  end

  @doc """
  Compares current state with a previous snapshot.
  """
  @spec compare_with_snapshot(pid(), binary()) :: :ok | {:error, [violation()]}
  def compare_with_snapshot(checker, snapshot_label) do
    GenServer.call(checker, {:compare_with_snapshot, snapshot_label})
  end

  @doc """
  Tracks a resource across services.
  """
  @spec track_resource(pid(), binary(), atom(), map()) :: :ok
  def track_resource(checker, resource_id, resource_type, initial_state) do
    GenServer.call(checker, {:track_resource, resource_id, resource_type, initial_state})
  end

  @doc """
  Updates tracked resource state.
  """
  @spec update_resource_state(pid(), binary(), service_name(), map()) :: :ok
  def update_resource_state(checker, resource_id, service, new_state) do
    GenServer.call(checker, {:update_resource_state, resource_id, service, new_state})
  end

  @doc """
  Removes a resource from tracking (when properly cleaned up).
  """
  @spec untrack_resource(pid(), binary()) :: :ok
  def untrack_resource(checker, resource_id) do
    GenServer.call(checker, {:untrack_resource, resource_id})
  end

  @doc """
  Adds a custom consistency rule.
  """
  @spec add_consistency_rule(pid(), atom(), (map() -> boolean()), binary()) :: :ok
  def add_consistency_rule(checker, rule_name, rule_fn, description) do
    GenServer.call(checker, {:add_consistency_rule, rule_name, rule_fn, description})
  end

  @doc """
  Gets detailed consistency report.
  """
  @spec get_consistency_report(pid()) :: map()
  def get_consistency_report(checker) do
    GenServer.call(checker, :get_consistency_report)
  end

  @doc """
  Validates specific business rules across services.
  """
  @spec validate_business_rules(pid(), %{service_name() => service_state()}) ::
          :ok | {:error, [violation()]}
  def validate_business_rules(checker, service_states) do
    GenServer.call(checker, {:validate_business_rules, service_states})
  end

  # GenServer implementation

  @impl true
  def init(state) do
    # Set up default consistency rules
    default_rules = [
      {:session_agent_consistency, &validate_session_agent_consistency/1,
       "Sessions and agents must be consistent"},
      {:registry_supervisor_consistency, &validate_registry_supervisor_consistency/1,
       "Registry and supervisor must agree on active processes"},
      {:no_orphaned_sessions, &validate_no_orphaned_sessions/1,
       "No sessions should exist without corresponding agents"},
      {:no_orphaned_agents, &validate_no_orphaned_agents/1,
       "No agents should exist without sessions"}
    ]

    new_state = %{state | consistency_rules: default_rules}
    {:ok, new_state}
  end

  @impl true
  def handle_call({:validate_consistency, service_states}, _from, state) do
    violations = []

    # Run all consistency rules
    rule_violations =
      Enum.flat_map(state.consistency_rules, fn {rule_name, rule_fn, description} ->
        case rule_fn.(service_states) do
          true ->
            []

          false ->
            [
              %{
                type: :consistency_rule_violation,
                rule: rule_name,
                description: description,
                services: Map.keys(service_states),
                details: service_states
              }
            ]

          {:error, details} ->
            [
              %{
                type: :consistency_rule_violation,
                rule: rule_name,
                description: description,
                services: Map.keys(service_states),
                details: details
              }
            ]
        end
      end)

    # Check resource consistency
    resource_violations = validate_tracked_resources(state.tracked_resources, service_states)

    all_violations = violations ++ rule_violations ++ resource_violations

    new_state = %{state | violations: all_violations ++ state.violations}

    result =
      if Enum.empty?(all_violations) do
        :ok
      else
        {:error, all_violations}
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:validate_clean_state, _from, state) do
    violations = []

    # Check for orphaned tracked resources
    orphaned_resources =
      Enum.filter(state.tracked_resources, fn {_id, resource} ->
        not resource_is_properly_cleaned(resource)
      end)

    orphan_violations =
      Enum.map(orphaned_resources, fn {resource_id, resource} ->
        %{
          type: :orphaned_resource,
          resource_id: resource_id,
          resource_type: resource.type,
          description: "Resource #{resource_id} was not properly cleaned up",
          details: resource
        }
      end)

    # Check system state against initial state
    current_state = capture_initial_state()
    state_violations = compare_system_states(state.start_state, current_state)

    all_violations = violations ++ orphan_violations ++ state_violations

    result =
      if Enum.empty?(all_violations) do
        :ok
      else
        {:error, all_violations}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:take_state_snapshot, label}, _from, state) do
    snapshot = %{
      label: label,
      timestamp: DateTime.utc_now(),
      system_state: capture_initial_state(),
      tracked_resources: state.tracked_resources
    }

    new_snapshots = [snapshot | state.state_snapshots]
    new_state = %{state | state_snapshots: new_snapshots}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:compare_with_snapshot, snapshot_label}, _from, state) do
    case Enum.find(state.state_snapshots, fn snapshot -> snapshot.label == snapshot_label end) do
      nil ->
        {:reply, {:error, :snapshot_not_found}, state}

      snapshot ->
        current_state = capture_initial_state()
        violations = compare_system_states(snapshot.system_state, current_state)

        result =
          if Enum.empty?(violations) do
            :ok
          else
            {:error, violations}
          end

        {:reply, result, state}
    end
  end

  @impl true
  def handle_call({:track_resource, resource_id, resource_type, initial_state}, _from, state) do
    resource = %{
      id: resource_id,
      type: resource_type,
      initial_state: initial_state,
      service_states: %{},
      created_at: DateTime.utc_now(),
      last_updated: DateTime.utc_now()
    }

    new_tracked = Map.put(state.tracked_resources, resource_id, resource)
    new_state = %{state | tracked_resources: new_tracked}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:update_resource_state, resource_id, service, new_state}, _from, state) do
    case Map.get(state.tracked_resources, resource_id) do
      nil ->
        {:reply, {:error, :resource_not_tracked}, state}

      resource ->
        updated_resource = %{
          resource
          | service_states: Map.put(resource.service_states, service, new_state),
            last_updated: DateTime.utc_now()
        }

        new_tracked = Map.put(state.tracked_resources, resource_id, updated_resource)
        new_state = %{state | tracked_resources: new_tracked}

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:untrack_resource, resource_id}, _from, state) do
    new_tracked = Map.delete(state.tracked_resources, resource_id)
    new_state = %{state | tracked_resources: new_tracked}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:add_consistency_rule, rule_name, rule_fn, description}, _from, state) do
    new_rule = {rule_name, rule_fn, description}
    new_rules = [new_rule | state.consistency_rules]
    new_state = %{state | consistency_rules: new_rules}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_consistency_report, _from, state) do
    report = %{
      total_violations: length(state.violations),
      violations: state.violations,
      tracked_resources: map_size(state.tracked_resources),
      consistency_rules: length(state.consistency_rules),
      state_snapshots: length(state.state_snapshots),
      system_health: assess_system_health(state)
    }

    {:reply, report, state}
  end

  @impl true
  def handle_call({:validate_business_rules, service_states}, _from, state) do
    violations = validate_arbor_business_rules(service_states)

    result =
      if Enum.empty?(violations) do
        :ok
      else
        {:error, violations}
      end

    {:reply, result, state}
  end

  # Private helper functions

  defp capture_initial_state do
    %{
      process_count: :erlang.system_info(:process_count),
      memory_usage: :erlang.memory(:total),
      ets_tables: length(:ets.all()),
      timestamp: DateTime.utc_now()
    }
  end

  # Default consistency rule implementations

  defp validate_session_agent_consistency(service_states) do
    gateway_state = Map.get(service_states, :gateway, %{})
    session_state = Map.get(service_states, :session_manager, %{})

    # Simple consistency check - handle both list and integer formats
    gateway_sessions =
      case Map.get(gateway_state, :active_sessions, 0) do
        sessions when is_list(sessions) -> length(sessions)
        count when is_integer(count) -> count
        _ -> 0
      end

    manager_sessions =
      case Map.get(session_state, :active_sessions, 0) do
        sessions when is_list(sessions) -> length(sessions)
        count when is_integer(count) -> count
        _ -> 0
      end

    gateway_sessions == manager_sessions
  end

  defp validate_registry_supervisor_consistency(service_states) do
    registry_state = Map.get(service_states, :registry, %{})
    supervisor_state = Map.get(service_states, :supervisor, %{})

    registered_agents = Map.get(registry_state, :registered_agents, 0)
    supervised_processes = Map.get(supervisor_state, :supervised_processes, 0)

    # Allow some tolerance for timing differences
    abs(registered_agents - supervised_processes) <= 1
  end

  defp validate_no_orphaned_sessions(service_states) do
    session_state = Map.get(service_states, :session_manager, %{})
    registry_state = Map.get(service_states, :registry, %{})

    active_sessions = Map.get(session_state, :active_sessions, 0)
    registered_agents = Map.get(registry_state, :registered_agents, 0)

    # Each session should have at least one agent
    active_sessions == 0 or registered_agents > 0
  end

  defp validate_no_orphaned_agents(service_states) do
    registry_state = Map.get(service_states, :registry, %{})
    session_state = Map.get(service_states, :session_manager, %{})

    registered_agents = Map.get(registry_state, :registered_agents, 0)
    active_sessions = Map.get(session_state, :active_sessions, 0)

    # Agents should belong to sessions
    registered_agents == 0 or active_sessions > 0
  end

  defp validate_tracked_resources(tracked_resources, service_states) do
    Enum.flat_map(tracked_resources, fn {resource_id, resource} ->
      check_resource_consistency(resource_id, resource, service_states)
    end)
  end

  defp check_resource_consistency(resource_id, resource, service_states) do
    # Check if resource state is consistent across services
    inconsistencies =
      Enum.flat_map(resource.service_states, fn {service, state} ->
        service_global_state = Map.get(service_states, service, %{})

        case validate_resource_in_service(resource_id, state, service_global_state) do
          :ok ->
            []

          {:error, reason} ->
            [
              %{
                type: :resource_inconsistency,
                resource_id: resource_id,
                service: service,
                description: "Resource inconsistency in #{service}",
                details: %{
                  reason: reason,
                  resource_state: state,
                  service_state: service_global_state
                }
              }
            ]
        end
      end)

    inconsistencies
  end

  defp validate_resource_in_service(_resource_id, _resource_state, _service_state) do
    # Placeholder - would implement actual validation logic
    :ok
  end

  defp resource_is_properly_cleaned(resource) do
    # Check if resource has been properly cleaned up
    # For now, just check if it's been updated recently
    case DateTime.diff(DateTime.utc_now(), resource.last_updated, :second) do
      # More than 5 minutes old
      diff when diff > 300 -> false
      _ -> true
    end
  end

  defp compare_system_states(initial_state, current_state) do
    violations = []

    # Check for significant process count increase
    process_diff = current_state.process_count - initial_state.process_count

    violations =
      if process_diff > 10 do
        [
          %{
            type: :process_leak,
            description: "Process count increased significantly",
            details: %{
              initial: initial_state.process_count,
              current: current_state.process_count,
              diff: process_diff
            }
          }
          | violations
        ]
      else
        violations
      end

    # Check for significant memory increase
    memory_diff = current_state.memory_usage - initial_state.memory_usage
    memory_increase_mb = memory_diff / (1024 * 1024)

    violations =
      if memory_increase_mb > 50 do
        [
          %{
            type: :memory_leak,
            description: "Memory usage increased significantly",
            details: %{
              initial_mb: initial_state.memory_usage / (1024 * 1024),
              current_mb: current_state.memory_usage / (1024 * 1024),
              increase_mb: memory_increase_mb
            }
          }
          | violations
        ]
      else
        violations
      end

    violations
  end

  defp assess_system_health(state) do
    %{
      total_violations: length(state.violations),
      critical_violations:
        length(Enum.filter(state.violations, &(&1.type in [:process_leak, :memory_leak]))),
      tracked_resources: map_size(state.tracked_resources),
      health_score: calculate_health_score(state)
    }
  end

  defp calculate_health_score(state) do
    base_score = 100
    violation_penalty = length(state.violations) * 10
    resource_penalty = if map_size(state.tracked_resources) > 5, do: 5, else: 0

    max(0, base_score - violation_penalty - resource_penalty)
  end

  defp validate_arbor_business_rules(service_states) do
    violations = []

    # Business rule: Gateway should not have more executions than sessions allow
    gateway_state = Map.get(service_states, :gateway, %{})
    session_state = Map.get(service_states, :session_manager, %{})

    active_executions = Map.get(gateway_state, :active_executions, 0)
    active_sessions = Map.get(session_state, :active_sessions, 0)

    # Allow up to 10 executions per session
    violations =
      if active_executions > active_sessions * 10 do
        [
          %{
            type: :business_rule_violation,
            rule: :execution_session_ratio,
            description: "Too many executions for available sessions",
            details: %{executions: active_executions, sessions: active_sessions}
          }
          | violations
        ]
      else
        violations
      end

    violations
  end
end
