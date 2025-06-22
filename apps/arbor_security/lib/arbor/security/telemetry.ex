defmodule Arbor.Security.Telemetry do
  @moduledoc """
  Telemetry instrumentation for the security system.

  Provides metrics and monitoring for:
  - SecurityKernel performance and mailbox size
  - Authorization latency
  - Cache hit rates
  - Audit event buffer status
  - Policy violations and security alerts
  """

  use GenServer
  require Logger

  # 5 seconds
  @periodic_measurements_interval 5_000

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec setup() :: :ok
  def setup do
    # Attach telemetry handlers
    handlers = [
      # SecurityKernel metrics
      {[:arbor, :security, :kernel, :call], &handle_kernel_call/4},
      {[:arbor, :security, :kernel, :mailbox], &handle_mailbox_size/4},

      # Authorization metrics
      {[:arbor, :security, :authorization, :start], &handle_auth_start/4},
      {[:arbor, :security, :authorization, :stop], &handle_auth_stop/4},
      {[:arbor, :security, :authorization, :exception], &handle_auth_exception/4},

      # Cache metrics
      {[:arbor, :security, :cache, :hit], &handle_cache_event/4},
      {[:arbor, :security, :cache, :miss], &handle_cache_event/4},

      # Audit metrics
      {[:arbor, :security, :audit, :flush_failed], &handle_audit_failure/4},
      {[:arbor, :security, :audit, :buffer_full], &handle_buffer_full/4},

      # Security events
      {[:arbor, :security, :policy, :violation], &handle_policy_violation/4},
      {[:arbor, :security, :capability, :revoked], &handle_capability_revoked/4}
    ]

    Enum.each(handlers, fn {event_name, handler} ->
      :telemetry.attach(
        "arbor-security-#{Enum.join(event_name, "-")}",
        event_name,
        handler,
        nil
      )
    end)

    :ok
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Schedule periodic measurements
    schedule_measurements()

    state = %{
      kernel_pid: Process.whereis(Arbor.Security.Kernel),
      capability_store_pid: Process.whereis(Arbor.Security.CapabilityStore),
      audit_logger_pid: Process.whereis(Arbor.Security.AuditLogger)
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:collect_measurements, state) do
    # Collect mailbox sizes for key processes
    collect_process_metrics(state)

    # Schedule next collection
    schedule_measurements()

    {:noreply, state}
  end

  # Private functions

  defp schedule_measurements do
    Process.send_after(self(), :collect_measurements, @periodic_measurements_interval)
  end

  defp collect_process_metrics(state) do
    # SecurityKernel mailbox size
    if state.kernel_pid && Process.alive?(state.kernel_pid) do
      {:message_queue_len, mailbox_size} = Process.info(state.kernel_pid, :message_queue_len)

      :telemetry.execute(
        [:arbor, :security, :kernel, :mailbox],
        %{size: mailbox_size},
        %{pid: state.kernel_pid}
      )

      # Alert if mailbox is getting large
      if mailbox_size > 1000 do
        Logger.warning("SecurityKernel mailbox size is high: #{mailbox_size} messages")
      end
    end

    # Similar for other critical processes
    collect_process_metric(state.capability_store_pid, [
      :arbor,
      :security,
      :capability_store,
      :mailbox
    ])

    collect_process_metric(state.audit_logger_pid, [:arbor, :security, :audit_logger, :mailbox])
  end

  defp collect_process_metric(nil, _event_name), do: :ok

  defp collect_process_metric(pid, event_name) when is_pid(pid) do
    if Process.alive?(pid) do
      {:message_queue_len, size} = Process.info(pid, :message_queue_len)
      :telemetry.execute(event_name, %{size: size}, %{pid: pid})
    end
  end

  # Telemetry handlers

  defp handle_kernel_call(_event_name, measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.debug("SecurityKernel call #{metadata.function} took #{duration_ms}ms")

    # Alert on slow operations
    if duration_ms > 100 do
      Logger.warning("Slow SecurityKernel operation: #{metadata.function} took #{duration_ms}ms")
    end
  end

  defp handle_mailbox_size(_event_name, measurements, metadata, _config) do
    if measurements.size > 500 do
      Logger.warning(
        "Process #{inspect(metadata.pid)} has high mailbox size: #{measurements.size}"
      )
    end
  end

  defp handle_auth_start(_event_name, _measurements, metadata, _config) do
    # Store start time in process dictionary for latency calculation
    Process.put({:auth_start, metadata.request_id}, System.monotonic_time())
  end

  defp handle_auth_stop(_event_name, _measurements, metadata, _config) do
    case Process.get({:auth_start, metadata.request_id}) do
      nil ->
        :ok

      start_time ->
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        Process.delete({:auth_start, metadata.request_id})

        Logger.debug("Authorization completed in #{duration_ms}ms for #{metadata.principal_id}")

        # Track authorization latency distribution
        :telemetry.execute(
          [:arbor, :security, :authorization, :latency],
          %{duration: duration_ms},
          metadata
        )
    end
  end

  defp handle_auth_exception(_event_name, measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error("Authorization failed after #{duration_ms}ms: #{inspect(metadata.reason)}")

    Process.delete({:auth_start, metadata.request_id})
  end

  defp handle_cache_event(event_name, _measurements, _metadata, _config) do
    # Cache events are high frequency, only log aggregates periodically
    cache_type = List.last(event_name)

    # You could aggregate these in ETS and report periodically
    Logger.debug("Cache #{cache_type}")
  end

  defp handle_audit_failure(_event_name, measurements, metadata, _config) do
    Logger.error("CRITICAL: Audit flush failed with #{measurements.buffer_size} events pending")

    # This should trigger alerts to operations team
    :telemetry.execute(
      [:arbor, :security, :critical_alert],
      measurements,
      Map.put(metadata, :alert_type, :audit_flush_failed)
    )
  end

  defp handle_buffer_full(_event_name, measurements, _metadata, _config) do
    Logger.warning("Audit buffer full: #{measurements.size} events")
  end

  defp handle_policy_violation(_event_name, _measurements, metadata, _config) do
    Logger.warning("Policy violation: #{metadata.policy} by #{metadata.principal_id}")

    # Track policy violations for security monitoring
    :telemetry.execute(
      [:arbor, :security, :violations],
      %{count: 1},
      metadata
    )
  end

  defp handle_capability_revoked(_event_name, _measurements, metadata, _config) do
    Logger.info("Capability revoked: #{metadata.capability_id} reason: #{metadata.reason}")
  end
end
