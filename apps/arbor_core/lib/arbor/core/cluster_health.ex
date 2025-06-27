defmodule Arbor.Core.ClusterHealth do
  @moduledoc """
  Shared health calculation and monitoring functions for cluster coordination.

  This module extracts common health-related logic that was duplicated between
  HordeCoordinator and LocalCoordinator, providing a single source of truth
  for cluster health calculations.
  """

  @behaviour Arbor.Contracts.Cluster.Health

  @doc """
  Calculates a balance score for the cluster based on load distribution.

  Returns a score from 0-100 where higher scores indicate better balance.
  """
  @spec calculate_balance_score(map()) :: number()
  def calculate_balance_score(nodes) do
    active_nodes = Enum.filter(nodes, fn {_node, info} -> info.status == :active end)

    case length(active_nodes) do
      0 ->
        0

      count ->
        loads = Enum.map(active_nodes, fn {_node, info} -> info.current_load end)
        avg_load = Enum.sum(loads) / count
        variance = Enum.sum(Enum.map(loads, fn load -> :math.pow(load - avg_load, 2) end)) / count
        # Lower variance = higher balance score
        max(0, 100 - variance)
    end
  end

  @doc """
  Generates health alerts based on metric updates.

  Adds new alerts to the existing list, keeping only the most recent 5.
  """
  @spec generate_health_alerts(map(), list()) :: list()
  def generate_health_alerts(health_update, existing_alerts) do
    new_alert =
      case {health_update.metric, health_update.value} do
        {:memory_usage, value} when value >= 95 ->
          %{
            metric: :memory_usage,
            severity: :critical,
            threshold_exceeded: true,
            timestamp: health_update.timestamp
          }

        {:memory_usage, value} when value >= 80 ->
          %{
            metric: :memory_usage,
            severity: :high,
            threshold_exceeded: true,
            timestamp: health_update.timestamp
          }

        {:cpu_usage, value} when value >= 90 ->
          %{
            metric: :cpu_usage,
            severity: :high,
            threshold_exceeded: true,
            timestamp: health_update.timestamp
          }

        _ ->
          nil
      end

    case new_alert do
      nil -> existing_alerts
      # Keep last 5 alerts
      alert -> [alert | Enum.take(existing_alerts, 4)]
    end
  end

  @doc """
  Determines the health status of a node based on its metrics and alerts.

  Returns one of: :critical, :warning, :caution, :healthy
  """
  @spec determine_node_health_status(map()) :: atom()
  def determine_node_health_status(health_data) do
    critical_alerts = Enum.count(health_data.alerts, fn alert -> alert.severity == :critical end)
    high_alerts = Enum.count(health_data.alerts, fn alert -> alert.severity == :high end)

    cond do
      critical_alerts > 0 -> :critical
      high_alerts > 0 -> :warning
      health_data.memory_usage > 70 or health_data.cpu_usage > 70 -> :caution
      true -> :healthy
    end
  end

  @doc """
  Calculates the overall health status of the cluster based on individual node health.

  Returns one of: :critical, :degraded, :warning, :healthy
  """
  @spec calculate_overall_health_status(list()) :: atom()
  def calculate_overall_health_status(nodes_health) do
    critical_count = Enum.count(nodes_health, fn node -> node.health_status == :critical end)
    warning_count = Enum.count(nodes_health, fn node -> node.health_status == :warning end)

    cond do
      critical_count > 0 -> :critical
      warning_count > length(nodes_health) / 2 -> :degraded
      warning_count > 0 -> :warning
      true -> :healthy
    end
  end

  @doc """
  Counts the total number of critical alerts across all nodes.
  """
  @spec count_critical_alerts(list()) :: integer()
  def count_critical_alerts(nodes_health) do
    Enum.sum(
      Enum.map(nodes_health, fn node ->
        Enum.count(node.alerts, fn alert -> alert.severity == :critical end)
      end)
    )
  end

  # Implement required callbacks from Arbor.Contracts.Cluster.Health

  @impl true
  def start_service(_config) do
    # This is a utility module that provides health calculation functions
    # No actual service to start
    {:ok, self()}
  end

  @impl true
  def stop_service(_reason) do
    # This is a utility module, nothing to stop
    :ok
  end

  @impl true
  def get_status do
    # Return status of the health calculation service
    status = %{
      module: __MODULE__,
      operational: true,
      timestamp: System.system_time(:millisecond)
    }

    {:ok, status}
  end
end
