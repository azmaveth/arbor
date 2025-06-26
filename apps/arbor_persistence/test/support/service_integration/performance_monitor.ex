defmodule Arbor.Test.ServiceInteractionCase.PerformanceMonitor do
  @moduledoc """
  Monitors performance metrics during service interaction testing.

  This module tracks resource usage, timing, and throughput during
  integration tests to ensure service interactions meet performance
  requirements and detect regressions.

  ## Features

  - **Operation Timing**: Tracks duration of service operations
  - **Memory Monitoring**: Monitors memory usage during operations
  - **Process Tracking**: Counts processes spawned during operations
  - **Throughput Measurement**: Measures operations per second
  - **Resource Limits**: Validates operations stay within bounds
  - **Regression Detection**: Compares against baseline metrics

  ## Usage

      monitor = PerformanceMonitor.start()
      
      # Start measuring an operation
      PerformanceMonitor.start_measurement(monitor, :gateway_command)
      
      # ... perform operation ...
      
      # End measurement
      PerformanceMonitor.end_measurement(monitor, :gateway_command)
      
      # Get metrics
      metrics = PerformanceMonitor.get_metrics(monitor, :gateway_command)
  """

  use GenServer

  @type operation_name :: atom()
  @type measurement_id :: reference()
  @type resource_metrics :: %{
          duration_ms: non_neg_integer(),
          memory_mb: float(),
          process_count: non_neg_integer(),
          cpu_usage_percent: float()
        }
  @type measurement :: %{
          operation: operation_name(),
          start_time: integer(),
          end_time: integer() | nil,
          start_memory: non_neg_integer(),
          end_memory: non_neg_integer() | nil,
          start_process_count: non_neg_integer(),
          end_process_count: non_neg_integer() | nil,
          measurement_id: measurement_id()
        }

  defstruct measurements: %{},
            completed_metrics: %{},
            baselines: %{},
            start_system_info: nil

  @doc """
  Starts a new performance monitor.
  """
  @spec start() :: pid()
  def start do
    {:ok, pid} =
      GenServer.start_link(__MODULE__, %__MODULE__{
        start_system_info: capture_system_info()
      })

    pid
  end

  @doc """
  Starts measuring performance for an operation.
  """
  @spec start_measurement(pid(), operation_name()) :: measurement_id()
  def start_measurement(monitor, operation) do
    GenServer.call(monitor, {:start_measurement, operation})
  end

  @doc """
  Ends measurement for an operation.
  """
  @spec end_measurement(pid(), operation_name()) :: :ok
  def end_measurement(monitor, operation) do
    GenServer.call(monitor, {:end_measurement, operation})
  end

  @doc """
  Gets performance metrics for a completed operation.
  """
  @spec get_metrics(pid(), operation_name()) :: resource_metrics() | nil
  def get_metrics(monitor, operation) do
    GenServer.call(monitor, {:get_metrics, operation})
  end

  @doc """
  Gets all completed metrics.
  """
  @spec get_all_metrics(pid()) :: %{operation_name() => resource_metrics()}
  def get_all_metrics(monitor) do
    GenServer.call(monitor, :get_all_metrics)
  end

  @doc """
  Sets baseline metrics for comparison.
  """
  @spec set_baseline(pid(), operation_name(), resource_metrics()) :: :ok
  def set_baseline(monitor, operation, baseline_metrics) do
    GenServer.call(monitor, {:set_baseline, operation, baseline_metrics})
  end

  @doc """
  Validates that operation metrics are within acceptable limits.
  """
  @spec validate_limits(pid(), operation_name(), keyword()) :: :ok | {:error, [atom()]}
  def validate_limits(monitor, operation, limits) do
    GenServer.call(monitor, {:validate_limits, operation, limits})
  end

  @doc """
  Compares metrics against baseline with tolerance.
  """
  @spec compare_to_baseline(pid(), operation_name(), float()) :: :ok | {:error, map()}
  def compare_to_baseline(monitor, operation, tolerance_percent \\ 10.0) do
    GenServer.call(monitor, {:compare_to_baseline, operation, tolerance_percent})
  end

  @doc """
  Gets performance summary report.
  """
  @spec get_performance_report(pid()) :: map()
  def get_performance_report(monitor) do
    GenServer.call(monitor, :get_performance_report)
  end

  @doc """
  Measures execution time and resource usage of a function.
  """
  @spec measure_function(pid(), operation_name(), (-> any())) :: {any(), resource_metrics()}
  def measure_function(monitor, operation, fun) do
    measurement_id = start_measurement(monitor, operation)

    try do
      result = fun.()
      end_measurement(monitor, operation)
      metrics = get_metrics(monitor, operation)
      {result, metrics}
    rescue
      error ->
        end_measurement(monitor, operation)
        reraise error, __STACKTRACE__
    end
  end

  # GenServer implementation

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:start_measurement, operation}, _from, state) do
    measurement_id = make_ref()

    measurement = %{
      operation: operation,
      start_time: System.monotonic_time(:microsecond),
      end_time: nil,
      start_memory: get_memory_usage(),
      end_memory: nil,
      start_process_count: get_process_count(),
      end_process_count: nil,
      measurement_id: measurement_id
    }

    new_measurements = Map.put(state.measurements, operation, measurement)
    new_state = %{state | measurements: new_measurements}

    {:reply, measurement_id, new_state}
  end

  @impl true
  def handle_call({:end_measurement, operation}, _from, state) do
    case Map.get(state.measurements, operation) do
      nil ->
        {:reply, {:error, :measurement_not_found}, state}

      measurement ->
        end_time = System.monotonic_time(:microsecond)
        end_memory = get_memory_usage()
        end_process_count = get_process_count()

        completed_measurement = %{
          measurement
          | end_time: end_time,
            end_memory: end_memory,
            end_process_count: end_process_count
        }

        metrics = calculate_metrics(completed_measurement)

        new_state = %{
          state
          | measurements: Map.delete(state.measurements, operation),
            completed_metrics: Map.put(state.completed_metrics, operation, metrics)
        }

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:get_metrics, operation}, _from, state) do
    metrics = Map.get(state.completed_metrics, operation)
    {:reply, metrics, state}
  end

  @impl true
  def handle_call(:get_all_metrics, _from, state) do
    {:reply, state.completed_metrics, state}
  end

  @impl true
  def handle_call({:set_baseline, operation, baseline_metrics}, _from, state) do
    new_baselines = Map.put(state.baselines, operation, baseline_metrics)
    new_state = %{state | baselines: new_baselines}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:validate_limits, operation, limits}, _from, state) do
    case Map.get(state.completed_metrics, operation) do
      nil ->
        {:reply, {:error, :metrics_not_found}, state}

      metrics ->
        violations = check_limit_violations(metrics, limits)

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
  def handle_call({:compare_to_baseline, operation, tolerance_percent}, _from, state) do
    with %{} = metrics <- Map.get(state.completed_metrics, operation),
         %{} = baseline <- Map.get(state.baselines, operation) do
      comparison = compare_metrics(metrics, baseline, tolerance_percent)

      result =
        if comparison.within_tolerance do
          :ok
        else
          {:error, comparison}
        end

      {:reply, result, state}
    else
      nil ->
        {:reply, {:error, :metrics_or_baseline_not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_performance_report, _from, state) do
    report = %{
      total_operations: map_size(state.completed_metrics),
      operations: state.completed_metrics,
      baselines: state.baselines,
      system_info: %{
        start_info: state.start_system_info,
        current_info: capture_system_info()
      },
      summary: build_performance_summary(state.completed_metrics)
    }

    {:reply, report, state}
  end

  # Private helper functions

  defp capture_system_info do
    %{
      total_memory: get_total_memory(),
      process_count: get_process_count(),
      timestamp: DateTime.utc_now()
    }
  end

  defp get_memory_usage do
    case :erlang.memory(:total) do
      memory when is_integer(memory) -> memory
      _ -> 0
    end
  end

  defp get_total_memory do
    case :erlang.memory(:system) do
      memory when is_integer(memory) -> memory
      _ -> 0
    end
  end

  defp get_process_count do
    case :erlang.system_info(:process_count) do
      count when is_integer(count) -> count
      _ -> 0
    end
  end

  defp calculate_metrics(measurement) do
    duration_ms = div(measurement.end_time - measurement.start_time, 1000)
    memory_diff = measurement.end_memory - measurement.start_memory
    memory_mb = memory_diff / (1024 * 1024)
    process_diff = measurement.end_process_count - measurement.start_process_count

    %{
      duration_ms: duration_ms,
      memory_mb: Float.round(memory_mb, 2),
      process_count: process_diff,
      # Placeholder - CPU measurement is complex in BEAM
      cpu_usage_percent: 0.0
    }
  end

  defp check_limit_violations(metrics, limits) do
    violations = []

    violations =
      if max_duration = limits[:max_duration_ms] do
        if metrics.duration_ms > max_duration do
          [:duration_exceeded | violations]
        else
          violations
        end
      else
        violations
      end

    violations =
      if max_memory = limits[:max_memory_mb] do
        if metrics.memory_mb > max_memory do
          [:memory_exceeded | violations]
        else
          violations
        end
      else
        violations
      end

    violations =
      if max_processes = limits[:max_process_count] do
        if metrics.process_count > max_processes do
          [:process_count_exceeded | violations]
        else
          violations
        end
      else
        violations
      end

    violations
  end

  defp compare_metrics(metrics, baseline, tolerance_percent) do
    tolerance = tolerance_percent / 100.0

    duration_diff_percent =
      abs(metrics.duration_ms - baseline.duration_ms) / baseline.duration_ms * 100

    memory_diff_percent =
      abs(metrics.memory_mb - baseline.memory_mb) / max(baseline.memory_mb, 0.1) * 100

    process_diff_percent =
      abs(metrics.process_count - baseline.process_count) / max(baseline.process_count, 1) * 100

    %{
      within_tolerance:
        duration_diff_percent <= tolerance_percent and
          memory_diff_percent <= tolerance_percent and
          process_diff_percent <= tolerance_percent,
      duration_diff_percent: Float.round(duration_diff_percent, 2),
      memory_diff_percent: Float.round(memory_diff_percent, 2),
      process_diff_percent: Float.round(process_diff_percent, 2),
      tolerance_percent: tolerance_percent
    }
  end

  defp build_performance_summary(metrics) do
    if Enum.empty?(metrics) do
      %{
        total_operations: 0,
        avg_duration_ms: 0,
        total_memory_mb: 0,
        total_processes: 0
      }
    else
      durations = Enum.map(metrics, fn {_op, m} -> m.duration_ms end)
      memories = Enum.map(metrics, fn {_op, m} -> m.memory_mb end)
      processes = Enum.map(metrics, fn {_op, m} -> m.process_count end)

      %{
        total_operations: length(durations),
        avg_duration_ms: div(Enum.sum(durations), length(durations)),
        max_duration_ms: Enum.max(durations),
        min_duration_ms: Enum.min(durations),
        total_memory_mb: Float.round(Enum.sum(memories), 2),
        avg_memory_mb: Float.round(Enum.sum(memories) / length(memories), 2),
        total_processes: Enum.sum(processes),
        avg_processes: Float.round(Enum.sum(processes) / length(processes), 1)
      }
    end
  end
end
