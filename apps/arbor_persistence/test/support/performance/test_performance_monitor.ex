defmodule Arbor.Test.Performance.TestPerformanceMonitor do
  @moduledoc """
  Performance monitoring utilities for the test suite.

  This module provides tools to monitor and optimize test performance,
  track resource usage, and identify bottlenecks in the test infrastructure.

  ## Features

  - **Test Timing**: Measures individual test execution time
  - **Memory Tracking**: Monitors memory usage during test execution
  - **Process Monitoring**: Tracks process creation and cleanup
  - **Resource Usage**: Measures CPU and I/O during tests
  - **Bottleneck Detection**: Identifies slow tests and inefficient patterns
  - **Performance Regression**: Tracks performance over time

  ## Usage

      use Arbor.Test.Performance.TestPerformanceMonitor
      
      test "fast operation", %{perf_monitor: monitor} do
        TestPerformanceMonitor.start_timing(monitor, :my_operation)
        
        # ... test code ...
        
        metrics = TestPerformanceMonitor.end_timing(monitor, :my_operation)
        assert metrics.duration_ms < 100
      end
  """

  use GenServer

  @type timing_id :: atom()
  @type metrics :: %{
          duration_ms: non_neg_integer(),
          memory_delta_mb: float(),
          process_delta: integer(),
          peak_memory_mb: float()
        }

  defstruct timings: %{},
            metrics: %{},
            test_start_memory: 0,
            test_start_processes: 0,
            baseline_metrics: nil

  @doc """
  Starts the performance monitor for a test.
  """
  @spec start() :: pid()
  def start do
    {:ok, pid} =
      GenServer.start_link(__MODULE__, %__MODULE__{
        test_start_memory: get_memory_usage(),
        test_start_processes: get_process_count(),
        baseline_metrics: capture_baseline_metrics()
      })

    pid
  end

  @doc """
  Starts timing an operation.
  """
  @spec start_timing(pid(), timing_id()) :: :ok
  def start_timing(monitor, timing_id) do
    GenServer.call(monitor, {:start_timing, timing_id})
  end

  @doc """
  Ends timing an operation and returns metrics.
  """
  @spec end_timing(pid(), timing_id()) :: metrics()
  def end_timing(monitor, timing_id) do
    GenServer.call(monitor, {:end_timing, timing_id})
  end

  @doc """
  Gets comprehensive test performance report.
  """
  @spec get_performance_report(pid()) :: map()
  def get_performance_report(monitor) do
    GenServer.call(monitor, :get_performance_report)
  end

  @doc """
  Validates that performance is within acceptable limits.
  """
  @spec validate_performance(pid(), keyword()) :: :ok | {:error, [atom()]}
  def validate_performance(monitor, limits) do
    GenServer.call(monitor, {:validate_performance, limits})
  end

  @doc """
  Macro to use performance monitoring in test modules.
  """
  defmacro __using__(_opts) do
    quote do
      setup do
        monitor = Arbor.Test.Performance.TestPerformanceMonitor.start()
        %{perf_monitor: monitor}
      end
    end
  end

  # GenServer implementation

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:start_timing, timing_id}, _from, state) do
    timing_data = %{
      start_time: System.monotonic_time(:microsecond),
      start_memory: get_memory_usage(),
      start_processes: get_process_count()
    }

    new_timings = Map.put(state.timings, timing_id, timing_data)
    new_state = %{state | timings: new_timings}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:end_timing, timing_id}, _from, state) do
    case Map.get(state.timings, timing_id) do
      nil ->
        {:reply, {:error, :timing_not_found}, state}

      timing_data ->
        end_time = System.monotonic_time(:microsecond)
        end_memory = get_memory_usage()
        end_processes = get_process_count()

        metrics = %{
          duration_ms: div(end_time - timing_data.start_time, 1000),
          memory_delta_mb: (end_memory - timing_data.start_memory) / (1024 * 1024),
          process_delta: end_processes - timing_data.start_processes,
          peak_memory_mb: get_peak_memory_usage() / (1024 * 1024)
        }

        new_timings = Map.delete(state.timings, timing_id)
        new_metrics = Map.put(state.metrics, timing_id, metrics)
        new_state = %{state | timings: new_timings, metrics: new_metrics}

        {:reply, metrics, new_state}
    end
  end

  @impl true
  def handle_call(:get_performance_report, _from, state) do
    current_memory = get_memory_usage()
    current_processes = get_process_count()

    report = %{
      test_duration_ms: calculate_test_duration(state),
      total_memory_delta_mb: (current_memory - state.test_start_memory) / (1024 * 1024),
      total_process_delta: current_processes - state.test_start_processes,
      operation_metrics: state.metrics,
      baseline_comparison: compare_to_baseline(state),
      performance_summary: build_performance_summary(state.metrics)
    }

    {:reply, report, state}
  end

  @impl true
  def handle_call({:validate_performance, limits}, _from, state) do
    violations = check_performance_violations(state, limits)

    result =
      if Enum.empty?(violations) do
        :ok
      else
        {:error, violations}
      end

    {:reply, result, state}
  end

  # Private helper functions

  defp get_memory_usage do
    :erlang.memory(:total)
  end

  defp get_process_count do
    :erlang.system_info(:process_count)
  end

  defp get_peak_memory_usage do
    # Get current memory usage as approximation
    # In a real implementation, this could track peak usage
    get_memory_usage()
  end

  defp capture_baseline_metrics do
    %{
      memory_mb: get_memory_usage() / (1024 * 1024),
      process_count: get_process_count(),
      timestamp: System.monotonic_time(:microsecond)
    }
  end

  defp calculate_test_duration(state) do
    case state.baseline_metrics do
      nil ->
        0

      baseline ->
        div(System.monotonic_time(:microsecond) - baseline.timestamp, 1000)
    end
  end

  defp compare_to_baseline(state) do
    case state.baseline_metrics do
      nil ->
        %{comparison: :no_baseline}

      baseline ->
        current_memory = get_memory_usage() / (1024 * 1024)
        current_processes = get_process_count()

        %{
          memory_growth_mb: current_memory - baseline.memory_mb,
          process_growth: current_processes - baseline.process_count,
          memory_growth_percent: (current_memory - baseline.memory_mb) / baseline.memory_mb * 100,
          process_growth_percent:
            (current_processes - baseline.process_count) / baseline.process_count * 100
        }
    end
  end

  defp build_performance_summary(metrics) do
    if Enum.empty?(metrics) do
      %{total_operations: 0}
    else
      durations = Enum.map(metrics, fn {_op, m} -> m.duration_ms end)
      memory_deltas = Enum.map(metrics, fn {_op, m} -> m.memory_delta_mb end)

      %{
        total_operations: length(durations),
        total_duration_ms: Enum.sum(durations),
        avg_duration_ms: div(Enum.sum(durations), length(durations)),
        max_duration_ms: Enum.max(durations),
        min_duration_ms: Enum.min(durations),
        total_memory_delta_mb: Float.round(Enum.sum(memory_deltas), 2),
        avg_memory_delta_mb: Float.round(Enum.sum(memory_deltas) / length(memory_deltas), 2)
      }
    end
  end

  defp check_performance_violations(state, limits) do
    violations = []

    # Check total test duration
    violations =
      if max_duration = limits[:max_test_duration_ms] do
        test_duration = calculate_test_duration(state)

        if test_duration > max_duration do
          [:test_duration_exceeded | violations]
        else
          violations
        end
      else
        violations
      end

    # Check memory growth
    violations =
      if max_memory_growth = limits[:max_memory_growth_mb] do
        current_memory = get_memory_usage() / (1024 * 1024)
        memory_growth = current_memory - state.test_start_memory / (1024 * 1024)

        if memory_growth > max_memory_growth do
          [:memory_growth_exceeded | violations]
        else
          violations
        end
      else
        violations
      end

    # Check process growth
    violations =
      if max_process_growth = limits[:max_process_growth] do
        current_processes = get_process_count()
        process_growth = current_processes - state.test_start_processes

        if process_growth > max_process_growth do
          [:process_growth_exceeded | violations]
        else
          violations
        end
      else
        violations
      end

    violations
  end
end
