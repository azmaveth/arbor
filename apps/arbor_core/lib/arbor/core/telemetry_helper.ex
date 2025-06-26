defmodule Arbor.Core.TelemetryHelper do
  @moduledoc """
  Common telemetry helper functions to reduce code duplication across the system.

  This module provides reusable telemetry emission functions for common events
  like agent operations, reconciliation, and performance measurements.
  """

  @behaviour Arbor.Contracts.Telemetry.TelemetryHelper

  alias Arbor.Contracts.Telemetry.AgentEvent
  alias Arbor.Contracts.Telemetry.PerformanceEvent
  alias Arbor.Contracts.Telemetry.ReconciliationEvent

  require Logger

  @doc """
  Emit telemetry for a timed operation.

  Returns the result of the operation and the duration in milliseconds.

  Process telemetry operations for the given input.
  Currently supports timed operation execution.
  """
  @impl true
  @spec process(input :: any()) :: {:ok, output :: any()} | {:error, term()}
  def process({:timed_operation, event_prefix, operation_name, func, metadata}) do
    try do
      result = timed_operation(event_prefix, operation_name, func, metadata)
      {:ok, result}
    rescue
      error -> {:error, error}
    end
  end

  def process(_input) do
    {:error, :unsupported_operation}
  end

  @doc """
  Configure the telemetry helper with options.
  Currently no configuration options are supported.
  """
  @impl true
  @spec configure(options :: keyword()) :: :ok | {:error, term()}
  def configure(_options) do
    :ok
  end

  @spec timed_operation(atom(), atom(), function(), map()) :: {any(), non_neg_integer()}
  def timed_operation(event_prefix, operation_name, func, metadata \\ %{}) do
    start_time = System.monotonic_time(:millisecond)

    # Emit start event
    :telemetry.execute(
      [event_prefix, operation_name, :start],
      %{start_time: start_time},
      metadata
    )

    # Execute the operation
    result = func.()

    # Calculate duration
    duration_ms = System.monotonic_time(:millisecond) - start_time

    # Emit completion event
    :telemetry.execute(
      [event_prefix, operation_name, :complete],
      %{duration_ms: duration_ms},
      metadata
    )

    {result, duration_ms}
  end

  @doc """
  Emit telemetry for an operation with success/failure tracking.
  """
  @spec emit_operation_result(list(atom()), map(), map(), {:ok, any()} | {:error, any()}) :: :ok
  def emit_operation_result(event_name, measurements, metadata, result) do
    case result do
      {:ok, _} ->
        :telemetry.execute(
          event_name ++ [:success],
          measurements,
          metadata
        )

      {:error, reason} ->
        :telemetry.execute(
          event_name ++ [:failure],
          Map.put(measurements, :error_reason, inspect(reason)),
          Map.put(metadata, :error, reason)
        )
    end

    :ok
  end

  @doc """
  Emit telemetry for agent lifecycle events.

  This function builds a typed event contract, validates it, and emits it.
  For backward compatibility, it falls back to a basic telemetry emission
  if the contract cannot be built or validated.
  """
  @spec emit_agent_event(atom(), binary(), map(), map()) :: :ok
  def emit_agent_event(event_type, agent_id, measurements \\ %{}, metadata \\ %{}) do
    fallback = fn ->
      Logger.debug(fn ->
        "Could not build or validate typed agent event for '#{event_type}'. Falling back to basic emission."
      end)

      base_metadata = %{
        agent_id: agent_id,
        node: node(),
        timestamp: System.system_time(:millisecond)
      }

      :telemetry.execute(
        [:arbor, :agent, event_type],
        measurements,
        Map.merge(base_metadata, metadata)
      )

      :ok
    end

    with {:ok, event} <- build_agent_event(event_type, agent_id, measurements, metadata),
         :ok <- emit_typed_agent_event(event) do
      :ok
    else
      _error -> fallback.()
    end
  end

  @doc """
  Emits a pre-constructed and typed agent event.

  This function validates the event against its contract before emission.
  If validation is successful, the event is emitted via `:telemetry.execute/3`.
  If validation fails, an error is logged and `{:error, reason}` is returned.
  """
  @spec emit_typed_agent_event(AgentEvent.t()) :: :ok | {:error, term()}
  def emit_typed_agent_event(event) do
    case AgentEvent.validate(event) do
      :ok ->
        # The timestamp is a top-level field in the contract struct.
        # For :telemetry.execute, it's common to pass it in metadata.
        metadata = Map.put_new(event.metadata, :timestamp, event.timestamp)

        :telemetry.execute(
          event.event_name,
          event.measurements,
          metadata
        )

        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          "Invalid agent telemetry event. Event: #{inspect(event)}, Reason: #{inspect(reason)}"
        end)

        {:error, reason}
    end
  end

  @doc """
  Emit telemetry for reconciliation events.

  This function builds a typed event contract, validates it, and emits it.
  For backward compatibility, it falls back to a basic telemetry emission
  if the contract cannot be built or validated.
  """
  @spec emit_reconciliation_event(atom(), map(), map()) :: :ok
  def emit_reconciliation_event(event_type, measurements \\ %{}, metadata \\ %{}) do
    fallback = fn ->
      Logger.debug(fn ->
        "Could not build or validate typed reconciliation event for '#{event_type}'. Falling back to basic emission."
      end)

      base_metadata = %{
        node: node(),
        timestamp: System.system_time(:millisecond)
      }

      :telemetry.execute(
        [:arbor, :reconciliation, event_type],
        measurements,
        Map.merge(base_metadata, metadata)
      )

      :ok
    end

    with {:ok, event} <- build_reconciliation_event(event_type, measurements, metadata),
         :ok <- emit_typed_reconciliation_event(event) do
      :ok
    else
      _error -> fallback.()
    end
  end

  @doc """
  Emits a pre-constructed and typed reconciliation event.

  This function validates the event against its contract before emission.
  If validation is successful, the event is emitted via `:telemetry.execute/3`.
  If validation fails, an error is logged and `{:error, reason}` is returned.
  """
  @spec emit_typed_reconciliation_event(ReconciliationEvent.t()) :: :ok | {:error, term()}
  def emit_typed_reconciliation_event(event) do
    case ReconciliationEvent.validate(event) do
      :ok ->
        # The timestamp is a top-level field in the contract struct.
        # For :telemetry.execute, it's common to pass it in metadata.
        metadata = Map.put_new(event.metadata, :timestamp, event.timestamp)

        :telemetry.execute(
          event.event_name,
          event.measurements,
          metadata
        )

        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          "Invalid reconciliation telemetry event. Event: #{inspect(event)}, Reason: #{inspect(reason)}"
        end)

        {:error, reason}
    end
  end

  @doc """
  Emit telemetry for performance metrics.

  This function builds a typed event contract, validates it, and emits it.
  For backward compatibility, it falls back to a basic telemetry emission
  if the contract cannot be built or validated.
  """
  @spec emit_performance_metric(list(atom()), number(), map()) :: :ok
  def emit_performance_metric(metric_name, value, metadata \\ %{}) do
    fallback = fn ->
      Logger.debug(fn ->
        "Could not build or validate typed performance metric. Falling back to basic emission."
      end)

      :telemetry.execute(
        metric_name,
        %{value: value},
        Map.put(metadata, :node, node())
      )

      :ok
    end

    with {:ok, event} <- build_performance_event(metric_name, value, metadata),
         :ok <- emit_typed_performance_event(event) do
      :ok
    else
      _error -> fallback.()
    end
  end

  @doc """
  Emits a pre-constructed and typed performance event.

  This function validates the event against its contract before emission.
  If validation is successful, the event is emitted via `:telemetry.execute/3`.
  If validation fails, an error is logged and `{:error, reason}` is returned.
  """
  @spec emit_typed_performance_event(PerformanceEvent.t()) :: :ok | {:error, term()}
  def emit_typed_performance_event(event) do
    case PerformanceEvent.validate(event) do
      :ok ->
        # The timestamp is a top-level field in the contract struct.
        # For :telemetry.execute, it's common to pass it in metadata.
        metadata = Map.put_new(event.metadata, :timestamp, event.timestamp)

        :telemetry.execute(
          event.event_name,
          event.measurements,
          metadata
        )

        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          "Invalid performance telemetry event. Event: #{inspect(event)}, Reason: #{inspect(reason)}"
        end)

        {:error, reason}
    end
  end

  @doc """
  Batch emit multiple related telemetry events.
  """
  @spec batch_emit_events(list({list(atom()), map(), map()})) :: :ok
  def batch_emit_events(events) do
    Enum.each(events, fn {event_name, measurements, metadata} ->
      :telemetry.execute(event_name, measurements, metadata)
    end)

    :ok
  end

  @doc """
  Create a telemetry span for tracking operations with automatic timing.
  """
  @spec span(list(atom()), map(), function()) :: any()
  def span(event_name, metadata, func) do
    start_metadata =
      Map.merge(metadata, %{
        node: node(),
        start_time: System.system_time(:millisecond)
      })

    :telemetry.span(
      event_name,
      start_metadata,
      fn ->
        result = func.()
        {result, Map.put(metadata, :result, inspect(result))}
      end
    )
  end

  @doc """
  Emit health metrics with automatic threshold detection.
  """
  @spec emit_health_metric(atom(), atom(), number(), map()) :: :ok
  def emit_health_metric(component, metric, value, thresholds \\ %{}) do
    severity = determine_severity(metric, value, thresholds)

    :telemetry.execute(
      [:arbor, :health, component, metric],
      %{value: value},
      %{
        node: node(),
        severity: severity,
        threshold_exceeded: severity != :normal
      }
    )
  end

  # Private functions

  defp build_agent_event(event_type, agent_id, measurements, metadata) do
    case get_agent_event_module(event_type) do
      {:ok, struct_module} ->
        base_metadata = %{agent_id: agent_id, node: node()}

        event =
          struct(struct_module, %{
            measurements: measurements,
            metadata: Map.merge(metadata, base_metadata),
            timestamp: System.system_time(:native)
          })

        {:ok, event}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_agent_event_module(event_type) do
    agent_event_modules = %{
      start: AgentEvent.Start,
      stop: AgentEvent.Stop,
      restart: AgentEvent.Restart,
      restart_attempt: AgentEvent.RestartAttempt,
      restarted: AgentEvent.Restarted,
      restart_failed: AgentEvent.RestartFailed,
      cleanup_attempt: AgentEvent.CleanupAttempt,
      cleaned_up: AgentEvent.CleanedUp,
      cleanup_failed: AgentEvent.CleanupFailed
    }

    case Map.fetch(agent_event_modules, event_type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_event_type}
    end
  end

  defp build_reconciliation_event(event_type, measurements, metadata) do
    case get_reconciliation_event_module(event_type) do
      {:ok, struct_module} ->
        base_metadata = %{node: node()}

        event =
          struct(struct_module, %{
            measurements: measurements,
            metadata: Map.merge(metadata, base_metadata),
            timestamp: System.system_time(:native)
          })

        {:ok, event}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_reconciliation_event_module(event_type) do
    reconciliation_event_modules = %{
      start: ReconciliationEvent.Start,
      complete: ReconciliationEvent.Complete,
      lookup_performance: ReconciliationEvent.LookupPerformance,
      agent_discovery: ReconciliationEvent.AgentDiscovery,
      agent_restart_success: ReconciliationEvent.AgentRestartSuccess,
      agent_restart_failed: ReconciliationEvent.AgentRestartFailed,
      agent_restart_error: ReconciliationEvent.AgentRestartError,
      agent_cleanup_success: ReconciliationEvent.AgentCleanupSuccess,
      agent_cleanup_failed: ReconciliationEvent.AgentCleanupFailed,
      agent_cleanup_error: ReconciliationEvent.AgentCleanupError
    }

    case Map.fetch(reconciliation_event_modules, event_type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_event_type}
    end
  end

  defp build_performance_event(metric_name, value, metadata) do
    base_metadata = %{node: node()}

    event =
      struct(PerformanceEvent.Metric, %{
        event_name: metric_name,
        measurements: %{value: value},
        metadata: Map.merge(metadata, base_metadata),
        timestamp: System.system_time(:native)
      })

    {:ok, event}
  end

  defp determine_severity(_metric, value, thresholds) do
    critical = Map.get(thresholds, :critical)
    high = Map.get(thresholds, :high)
    medium = Map.get(thresholds, :medium)

    cond do
      critical && value >= critical -> :critical
      high && value >= high -> :high
      medium && value >= medium -> :medium
      true -> :normal
    end
  end
end
