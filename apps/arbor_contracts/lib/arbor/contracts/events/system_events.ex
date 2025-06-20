defmodule Arbor.Contracts.Events.SystemEvents do
  @moduledoc """
  Event definitions for system-wide activities and cluster operations.

  These events track infrastructure-level changes, cluster membership,
  performance metrics, and system health indicators.

  ## Event Categories

  - **Cluster Events**: Node join/leave, partitions
  - **Performance Events**: Resource usage, bottlenecks
  - **Maintenance Events**: Upgrades, configuration changes
  - **Alert Events**: System warnings and critical issues

  @version "1.0.0"
  """

  use TypedStruct

  # Node Joined Event
  defmodule NodeJoined do
    @moduledoc """
    Emitted when a node joins the cluster.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:node_name, atom())
      field(:node_type, atom(), default: :worker)
      field(:capabilities, [atom()], default: [])
      field(:resources, map(), default: %{})
      field(:cluster_size, pos_integer())
      field(:timestamp, DateTime.t())
    end
  end

  # Node Left Event
  defmodule NodeLeft do
    @moduledoc """
    Emitted when a node leaves the cluster.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:node_name, atom())
      field(:reason, atom() | String.t())
      field(:was_graceful, boolean(), default: false)
      field(:migrated_agents, non_neg_integer(), default: 0)
      field(:remaining_nodes, pos_integer())
      field(:timestamp, DateTime.t())
    end
  end

  # Network Partition Event
  defmodule NetworkPartition do
    @moduledoc """
    Emitted when a network partition is detected.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:partition_id, String.t())
      field(:nodes_side_a, [atom()])
      field(:nodes_side_b, [atom()])
      field(:detection_method, atom())
      field(:affected_services, [atom()], default: [])
      field(:timestamp, DateTime.t())
    end
  end

  # Partition Healed Event
  defmodule PartitionHealed do
    @moduledoc """
    Emitted when a network partition is resolved.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:partition_id, String.t())
      field(:duration, non_neg_integer())
      field(:reconciliation_status, atom())
      field(:conflicts_resolved, non_neg_integer(), default: 0)
      field(:timestamp, DateTime.t())
    end
  end

  # Resource Alert Event
  defmodule ResourceAlert do
    @moduledoc """
    Emitted when resource usage exceeds thresholds.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:node_name, atom())
      field(:resource_type, atom())
      field(:current_usage, float())
      field(:threshold, float())
      field(:severity, atom())
      field(:recommended_action, String.t(), enforce: false)
      field(:timestamp, DateTime.t())
    end
  end

  # Configuration Changed Event
  defmodule ConfigurationChanged do
    @moduledoc """
    Emitted when system configuration is modified.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:config_key, String.t())
      field(:old_value, any())
      field(:new_value, any())
      field(:changed_by, String.t())
      field(:change_reason, String.t())
      field(:requires_restart, boolean(), default: false)
      field(:timestamp, DateTime.t())
    end
  end

  # System Upgrade Started Event
  defmodule SystemUpgradeStarted do
    @moduledoc """
    Emitted when a system upgrade begins.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:upgrade_id, String.t())
      field(:from_version, String.t())
      field(:to_version, String.t())
      field(:upgrade_type, atom())
      field(:affected_nodes, [atom()])
      field(:estimated_duration, non_neg_integer())
      field(:timestamp, DateTime.t())
    end
  end

  # System Upgrade Completed Event
  defmodule SystemUpgradeCompleted do
    @moduledoc """
    Emitted when a system upgrade finishes.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:upgrade_id, String.t())
      field(:success, boolean())
      field(:duration, non_neg_integer())
      field(:nodes_upgraded, non_neg_integer())
      field(:rollback_performed, boolean(), default: false)
      field(:issues_encountered, [String.t()], default: [])
      field(:timestamp, DateTime.t())
    end
  end

  # Performance Degradation Event
  defmodule PerformanceDegradation do
    @moduledoc """
    Emitted when system performance degrades.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:metric_type, atom())
      field(:current_value, float())
      field(:baseline_value, float())
      field(:degradation_percent, float())
      field(:affected_components, [atom()], default: [])
      field(:possible_causes, [String.t()], default: [])
      field(:timestamp, DateTime.t())
    end
  end

  # Cluster Rebalance Event
  defmodule ClusterRebalanced do
    @moduledoc """
    Emitted when cluster load is rebalanced.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:rebalance_id, String.t())
      field(:trigger_reason, atom())
      field(:agents_migrated, non_neg_integer())
      field(:data_transferred_bytes, non_neg_integer())
      field(:duration, non_neg_integer())
      field(:new_distribution, map())
      field(:timestamp, DateTime.t())
    end
  end

  # Security Incident Event
  defmodule SecurityIncident do
    @moduledoc """
    Emitted when a security incident is detected.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:incident_id, String.t())
      field(:incident_type, atom())
      field(:severity, atom())
      field(:source, String.t())
      field(:affected_resources, [String.t()], default: [])
      field(:action_taken, atom())
      field(:details, map(), default: %{})
      field(:timestamp, DateTime.t())
    end
  end

  # Backup Started Event
  defmodule BackupStarted do
    @moduledoc """
    Emitted when a system backup begins.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:backup_id, String.t())
      field(:backup_type, atom())
      field(:included_components, [atom()])
      field(:destination, String.t())
      field(:estimated_size_bytes, non_neg_integer())
      field(:timestamp, DateTime.t())
    end
  end

  # Backup Completed Event
  defmodule BackupCompleted do
    @moduledoc """
    Emitted when a system backup finishes.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:backup_id, String.t())
      field(:success, boolean())
      field(:duration, non_neg_integer())
      field(:size_bytes, non_neg_integer())
      field(:items_backed_up, non_neg_integer())
      field(:verification_status, atom())
      field(:timestamp, DateTime.t())
    end
  end

  # System Health Report Event
  defmodule SystemHealthReport do
    @moduledoc """
    Periodic system health summary event.
    """

    use TypedStruct

    @derive Jason.Encoder
    typedstruct enforce: true do
      field(:report_id, String.t())
      field(:overall_health, atom())
      field(:cluster_nodes, pos_integer())
      field(:active_sessions, non_neg_integer())
      field(:active_agents, non_neg_integer())
      field(:memory_usage_percent, float())
      field(:cpu_usage_percent, float())
      field(:error_rate, float())
      field(:warnings, [String.t()], default: [])
      field(:recommendations, [String.t()], default: [])
      field(:timestamp, DateTime.t())
    end
  end
end
