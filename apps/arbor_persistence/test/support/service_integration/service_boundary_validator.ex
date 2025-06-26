defmodule Arbor.Test.ServiceInteractionCase.ServiceBoundaryValidator do
  @moduledoc """
  Validates service boundary interactions and contract compliance.

  This module tracks and validates all interactions between Arbor services,
  ensuring that service boundaries are respected and contracts are followed.
  It helps detect interface violations and unexpected service dependencies.

  ## Features

  - **Contract Validation**: Ensures all service calls follow defined interfaces
  - **Boundary Tracking**: Monitors cross-service call patterns
  - **Dependency Detection**: Identifies unexpected service dependencies
  - **Error Context**: Provides detailed context for boundary violations
  - **Performance Impact**: Tracks service interaction overhead

  ## Usage

      validator = ServiceBoundaryValidator.start()
      
      # Track a service call
      ServiceBoundaryValidator.track_call(validator, :gateway, :create_session)
      
      # Validate call sequence
      assert ServiceBoundaryValidator.validate_call_sequence(validator, [
        {:gateway, :create_session},
        {:session_manager, :register_session},
        {:pubsub, :broadcast_event}
      ])
  """

  use GenServer

  @type service_name :: :gateway | :session_manager | :registry | :supervisor | :pubsub
  @type operation_name :: atom()
  @type call_info :: %{
          service: service_name(),
          operation: operation_name(),
          timestamp: DateTime.t(),
          duration_ms: non_neg_integer(),
          success: boolean(),
          error: term()
        }

  defstruct calls: [],
            error_scenarios: [],
            violations: [],
            started_at: nil

  @doc """
  Starts a new service boundary validator.
  """
  @spec start() :: pid()
  def start do
    {:ok, pid} =
      GenServer.start_link(__MODULE__, %__MODULE__{
        started_at: DateTime.utc_now()
      })

    pid
  end

  @doc """
  Tracks a service call with timing and success information.
  """
  @spec track_call(pid(), service_name(), operation_name(), keyword()) :: :ok
  def track_call(validator, service, operation, opts \\ []) do
    call_info = %{
      service: service,
      operation: operation,
      timestamp: DateTime.utc_now(),
      duration_ms: Keyword.get(opts, :duration_ms, 0),
      success: Keyword.get(opts, :success, true),
      error: Keyword.get(opts, :error),
      context: Keyword.get(opts, :context, %{})
    }

    GenServer.call(validator, {:track_call, call_info})
  end

  @doc """
  Tracks an error scenario for validation testing.
  """
  @spec track_error_scenario(pid(), atom()) :: :ok
  def track_error_scenario(validator, scenario) do
    GenServer.call(validator, {:track_error_scenario, scenario})
  end

  @doc """
  Validates that service calls follow expected sequence.
  """
  @spec validate_call_sequence(pid(), [{service_name(), operation_name()}]) :: boolean()
  def validate_call_sequence(validator, expected_sequence) do
    GenServer.call(validator, {:validate_call_sequence, expected_sequence})
  end

  @doc """
  Validates that no unexpected service dependencies were created.
  """
  @spec validate_no_unexpected_dependencies(pid(), map()) :: :ok | {:error, term()}
  def validate_no_unexpected_dependencies(validator, allowed_dependencies) do
    GenServer.call(validator, {:validate_dependencies, allowed_dependencies})
  end

  @doc """
  Gets detailed validation report with all tracked calls and violations.
  """
  @spec get_validation_report(pid()) :: map()
  def get_validation_report(validator) do
    GenServer.call(validator, :get_validation_report)
  end

  @doc """
  Validates service boundary contract compliance.
  """
  @spec validate_contracts(pid()) :: :ok | {:error, [term()]}
  def validate_contracts(validator) do
    GenServer.call(validator, :validate_contracts)
  end

  # GenServer implementation

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:track_call, call_info}, _from, state) do
    # Validate the call against known service contracts
    violation = validate_call_contract(call_info)

    new_state = %{
      state
      | calls: [call_info | state.calls],
        violations: if(violation, do: [violation | state.violations], else: state.violations)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:track_error_scenario, scenario}, _from, state) do
    new_state = %{state | error_scenarios: [scenario | state.error_scenarios]}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:validate_call_sequence, expected_sequence}, _from, state) do
    actual_sequence =
      state.calls
      |> Enum.reverse()
      |> Enum.map(fn call -> {call.service, call.operation} end)

    result = sequence_matches?(actual_sequence, expected_sequence)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:validate_dependencies, allowed_dependencies}, _from, state) do
    violations = find_dependency_violations(state.calls, allowed_dependencies)

    result =
      if Enum.empty?(violations) do
        :ok
      else
        {:error, violations}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_validation_report, _from, state) do
    report = %{
      total_calls: length(state.calls),
      violations: state.violations,
      error_scenarios: state.error_scenarios,
      call_timeline: Enum.reverse(state.calls),
      service_interaction_map: build_interaction_map(state.calls),
      performance_summary: build_performance_summary(state.calls)
    }

    {:reply, report, state}
  end

  @impl true
  def handle_call(:validate_contracts, _from, state) do
    contract_violations =
      Enum.filter(state.violations, fn violation ->
        violation.type == :contract_violation
      end)

    result =
      if Enum.empty?(contract_violations) do
        :ok
      else
        {:error, contract_violations}
      end

    {:reply, result, state}
  end

  # Private helper functions

  defp validate_call_contract(call_info) do
    case validate_service_operation(call_info.service, call_info.operation) do
      :ok ->
        nil

      {:error, reason} ->
        %{
          type: :contract_violation,
          service: call_info.service,
          operation: call_info.operation,
          reason: reason,
          timestamp: call_info.timestamp
        }
    end
  end

  defp validate_service_operation(:gateway, operation) do
    allowed_operations = [
      :execute_command,
      :get_execution_status,
      :subscribe_execution,
      :get_capabilities
    ]

    if operation in allowed_operations do
      :ok
    else
      {:error, "Unknown gateway operation: #{operation}"}
    end
  end

  defp validate_service_operation(:session_manager, operation) do
    allowed_operations = [:create_session, :get_session, :update_session, :terminate_session]

    if operation in allowed_operations do
      :ok
    else
      {:error, "Unknown session manager operation: #{operation}"}
    end
  end

  defp validate_service_operation(:registry, operation) do
    allowed_operations = [:register_name, :unregister_name, :lookup_name, :whereis_name]

    if operation in allowed_operations do
      :ok
    else
      {:error, "Unknown registry operation: #{operation}"}
    end
  end

  defp validate_service_operation(:supervisor, operation) do
    allowed_operations = [:start_child, :terminate_child, :which_children, :count_children]

    if operation in allowed_operations do
      :ok
    else
      {:error, "Unknown supervisor operation: #{operation}"}
    end
  end

  defp validate_service_operation(:pubsub, operation) do
    allowed_operations = [:subscribe, :unsubscribe, :broadcast, :publish]

    if operation in allowed_operations do
      :ok
    else
      {:error, "Unknown pubsub operation: #{operation}"}
    end
  end

  defp validate_service_operation(service, _operation) do
    {:error, "Unknown service: #{service}"}
  end

  defp sequence_matches?(actual, expected) do
    # Simple subsequence matching - actual can have more calls than expected
    # but expected calls must appear in the same order
    find_subsequence(actual, expected)
  end

  defp find_subsequence(_actual, []), do: true
  defp find_subsequence([], _expected), do: false

  defp find_subsequence([h | actual_tail], [h | expected_tail]) do
    find_subsequence(actual_tail, expected_tail)
  end

  defp find_subsequence([_h | actual_tail], expected) do
    find_subsequence(actual_tail, expected)
  end

  defp find_dependency_violations(calls, allowed_dependencies) do
    # Find service interactions that violate dependency rules
    service_pairs =
      calls
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [call1, call2] -> {call1.service, call2.service} end)
      |> Enum.uniq()

    Enum.filter(service_pairs, fn {from_service, to_service} ->
      not dependency_allowed?(from_service, to_service, allowed_dependencies)
    end)
  end

  defp dependency_allowed?(from_service, to_service, allowed_dependencies) do
    case allowed_dependencies[from_service] do
      nil ->
        false

      allowed_targets when is_list(allowed_targets) ->
        to_service in allowed_targets

      :any ->
        true
    end
  end

  defp build_interaction_map(calls) do
    calls
    |> Enum.group_by(& &1.service)
    |> Map.new(fn {service, service_calls} ->
      {service,
       %{
         total_calls: length(service_calls),
         operations: Enum.map(service_calls, & &1.operation) |> Enum.frequencies(),
         success_rate: calculate_success_rate(service_calls),
         avg_duration_ms: calculate_avg_duration(service_calls)
       }}
    end)
  end

  defp build_performance_summary(calls) do
    %{
      total_duration_ms: Enum.sum(Enum.map(calls, & &1.duration_ms)),
      avg_call_duration_ms: calculate_avg_duration(calls),
      slowest_calls: Enum.sort_by(calls, & &1.duration_ms, :desc) |> Enum.take(5),
      success_rate: calculate_success_rate(calls)
    }
  end

  defp calculate_success_rate(calls) do
    if Enum.empty?(calls) do
      1.0
    else
      successful_calls = Enum.count(calls, & &1.success)
      successful_calls / length(calls)
    end
  end

  defp calculate_avg_duration(calls) do
    if Enum.empty?(calls) do
      0
    else
      total_duration = Enum.sum(Enum.map(calls, & &1.duration_ms))
      total_duration / length(calls)
    end
  end
end
