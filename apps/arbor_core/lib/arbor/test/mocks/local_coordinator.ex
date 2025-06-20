defmodule Arbor.Test.Mocks.LocalCoordinator do
  @moduledoc """
  MOCK implementation of cluster coordination for single-node testing.

  This provides a local-only implementation of cluster coordination logic for
  unit testing distributed coordination patterns without requiring actual clustering.

  IMPORTANT: This is a MOCK - replace with Horde-based coordination for distributed operation!

  Handles:
  - Node lifecycle management (join/leave/failure)
  - Agent redistribution planning
  - Cluster state synchronization
  - Load balancing and health monitoring
  """

  use Agent

  defstruct [
    :nodes,
    :agents,
    :event_log,
    :health_metrics,
    :sync_status,
    :redistribution_plans
  ]

  @type state :: %__MODULE__{
          nodes: %{node() => node_info()},
          agents: %{binary() => agent_info()},
          event_log: [coordination_event()],
          health_metrics: %{node() => health_data()},
          sync_status: sync_info(),
          redistribution_plans: [redistribution_plan()]
        }

  @type node_info :: %{
          node: node(),
          status: :active | :inactive | :failed,
          capacity: non_neg_integer(),
          current_load: non_neg_integer(),
          capabilities: [atom()],
          resources: map(),
          joined_at: integer(),
          agent_count: non_neg_integer()
        }

  @type agent_info :: %{
          id: binary(),
          node: node(),
          type: atom(),
          priority: atom(),
          resources: map(),
          assigned_at: integer()
        }

  @type coordination_event :: %{
          type: atom(),
          data: any(),
          timestamp: integer(),
          processed: boolean()
        }

  @type health_data :: %{
          memory_usage: non_neg_integer(),
          cpu_usage: non_neg_integer(),
          alerts: [alert()],
          last_updated: integer()
        }

  @type alert :: %{
          metric: atom(),
          severity: :low | :medium | :high | :critical,
          threshold_exceeded: boolean(),
          timestamp: integer()
        }

  @type sync_info :: %{
          last_sync_timestamp: integer(),
          coordinator_nodes: [node()],
          sync_conflicts: [map()],
          partition_status: map()
        }

  @type redistribution_plan :: %{
          trigger_node: node(),
          agents_to_migrate: [binary()],
          target_nodes: [node()],
          reason: atom(),
          created_at: integer()
        }

  # Client API

  def start_link(_opts \\ []) do
    Agent.start_link(
      fn ->
        %__MODULE__{
          nodes: %{},
          agents: %{},
          event_log: [],
          health_metrics: %{},
          sync_status: %{
            last_sync_timestamp: 0,
            coordinator_nodes: [],
            sync_conflicts: [],
            partition_status: %{}
          },
          redistribution_plans: []
        }
      end,
      name: __MODULE__
    )
  end

  def clear() do
    Agent.update(__MODULE__, fn _state ->
      %__MODULE__{
        nodes: %{},
        agents: %{},
        event_log: [],
        health_metrics: %{},
        sync_status: %{
          last_sync_timestamp: 0,
          coordinator_nodes: [],
          sync_conflicts: [],
          partition_status: %{}
        },
        redistribution_plans: []
      }
    end)
  end

  def init(_opts) do
    state = %__MODULE__{
      nodes: %{},
      agents: %{},
      event_log: [],
      health_metrics: %{},
      sync_status: %{
        last_sync_timestamp: 0,
        coordinator_nodes: [],
        sync_conflicts: [],
        partition_status: %{}
      },
      redistribution_plans: []
    }

    {:ok, state}
  end

  # Node lifecycle management

  def handle_node_join(node_info, _state) do
    Agent.update(__MODULE__, fn state ->
      node_data = %{
        node: node_info.node,
        status: :active,
        capacity: node_info.capacity,
        current_load: 0,
        capabilities: node_info.capabilities,
        resources: Map.get(node_info, :resources, %{}),
        joined_at: System.system_time(:millisecond),
        agent_count: 0
      }

      updated_nodes = Map.put(state.nodes, node_info.node, node_data)

      # If this is a coordinator node, add it to coordinator nodes list
      updated_sync_status =
        if Map.get(node_info, :role) == :coordinator do
          current_coordinators = state.sync_status.coordinator_nodes
          %{state.sync_status | coordinator_nodes: [node_info.node | current_coordinators]}
        else
          state.sync_status
        end

      %{state | nodes: updated_nodes, sync_status: updated_sync_status}
    end)

    :ok
  end

  def handle_node_leave(node, _reason, _state) do
    Agent.update(__MODULE__, fn state ->
      case Map.get(state.nodes, node) do
        nil ->
          state

        node_data ->
          updated_node = %{node_data | status: :inactive}
          updated_nodes = Map.put(state.nodes, node, updated_node)
          %{state | nodes: updated_nodes}
      end
    end)

    :ok
  end

  def handle_node_failure(node, _reason, _state) do
    Agent.update(__MODULE__, fn state ->
      case Map.get(state.nodes, node) do
        nil ->
          state

        node_data ->
          updated_node = %{node_data | status: :failed}
          updated_nodes = Map.put(state.nodes, node, updated_node)

          # Create redistribution plan for agents on failed node
          agents_on_node =
            state.agents
            |> Enum.filter(fn {_id, agent} -> agent.node == node end)
            |> Enum.map(fn {id, _agent} -> id end)

          available_nodes =
            state.nodes
            |> Enum.filter(fn {node_name, info} ->
              info.status == :active and node_name != node
            end)
            |> Enum.map(fn {node_name, _info} -> node_name end)

          redistribution_plan = %{
            trigger_node: node,
            agents_to_migrate: agents_on_node,
            target_nodes: available_nodes,
            reason: :node_failure,
            created_at: System.system_time(:millisecond)
          }

          updated_plans = [redistribution_plan | state.redistribution_plans]

          %{state | nodes: updated_nodes, redistribution_plans: updated_plans}
      end
    end)

    :ok
  end

  def get_cluster_info(_state) do
    Agent.get(__MODULE__, fn state ->
      cluster_info = %{
        nodes: Map.values(state.nodes),
        total_capacity: Enum.sum(Enum.map(state.nodes, fn {_node, info} -> info.capacity end)),
        active_nodes: Enum.count(state.nodes, fn {_node, info} -> info.status == :active end),
        total_agents: map_size(state.agents)
      }

      {:ok, cluster_info}
    end)
  end

  def get_redistribution_plan(node, _state) do
    Agent.get(__MODULE__, fn state ->
      plan =
        Enum.find(state.redistribution_plans, fn plan ->
          plan.trigger_node == node
        end)

      case plan do
        nil -> {:error, :no_plan_found}
        plan -> {:ok, plan}
      end
    end)
  end

  # Agent management

  def register_agent_on_node(agent_info, _state) do
    Agent.update(__MODULE__, fn state ->
      agent_data = %{
        id: agent_info.id,
        node: agent_info.node,
        type: agent_info.type,
        priority: Map.get(agent_info, :priority, :normal),
        resources: Map.get(agent_info, :resources, %{}),
        assigned_at: System.system_time(:millisecond)
      }

      updated_agents = Map.put(state.agents, agent_info.id, agent_data)

      # Update node agent count
      updated_nodes =
        Map.update(state.nodes, agent_info.node, %{}, fn node_data ->
          %{node_data | agent_count: node_data.agent_count + 1}
        end)

      %{state | agents: updated_agents, nodes: updated_nodes}
    end)

    :ok
  end

  def calculate_distribution(agents, _state) do
    Agent.get(__MODULE__, fn state ->
      assignments =
        Enum.map(agents, fn agent ->
          # Find compatible nodes for agent type
          compatible_nodes =
            state.nodes
            |> Enum.filter(fn {_node, info} ->
              info.status == :active and agent.type in info.capabilities
            end)
            # Prefer less loaded nodes
            |> Enum.sort_by(fn {_node, info} -> info.current_load end)

          target_node =
            case compatible_nodes do
              [] -> nil
              [{node, _info} | _] -> node
            end

          %{
            agent_id: agent.id,
            target_node: target_node,
            assignment_reason: :load_balancing
          }
        end)

      distribution_plan = %{
        assignments: assignments,
        strategy: :least_loaded,
        created_at: System.system_time(:millisecond)
      }

      {:ok, distribution_plan}
    end)
  end

  def update_node_capacity(capacity_update, _state) do
    Agent.update(__MODULE__, fn state ->
      case Map.get(state.nodes, capacity_update.node) do
        nil ->
          state

        node_data ->
          updated_node = %{node_data | capacity: capacity_update.new_capacity}
          updated_nodes = Map.put(state.nodes, capacity_update.node, updated_node)
          %{state | nodes: updated_nodes}
      end
    end)

    :ok
  end

  def suggest_redistribution(_state) do
    Agent.get(__MODULE__, fn state ->
      # Find overloaded nodes (load > 80% of capacity OR capacity < 50)
      overloaded_nodes =
        state.nodes
        |> Enum.filter(fn {_node, info} ->
          info.status == :active and
            (info.current_load / max(info.capacity, 1) > 0.8 or info.capacity < 50)
        end)

      agents_to_migrate =
        overloaded_nodes
        |> Enum.flat_map(fn {node, _info} ->
          state.agents
          |> Enum.filter(fn {_id, agent} -> agent.node == node end)
          |> Enum.map(fn {id, _agent} -> id end)
          # Migrate one agent per overloaded node
          |> Enum.take(1)
        end)

      redistribution_plan = %{
        agents_to_migrate: agents_to_migrate,
        reason: :capacity_exceeded,
        created_at: System.system_time(:millisecond)
      }

      {:ok, redistribution_plan}
    end)
  end

  # Cluster state synchronization

  def synchronize_cluster_state(state_update, _state) do
    Agent.update(__MODULE__, fn state ->
      # Process each update in the state synchronization
      processed_updates =
        Enum.map(state_update.updates, fn update ->
          case update do
            {:agent_started, agent_id, node} ->
              agent_data = %{
                id: agent_id,
                node: node,
                type: :unknown,
                priority: :normal,
                resources: %{},
                assigned_at: state_update.timestamp
              }

              updated_agents = Map.put(state.agents, agent_id, agent_data)
              %{state | agents: updated_agents}

            {:agent_stopped, agent_id, _node} ->
              updated_agents = Map.delete(state.agents, agent_id)
              %{state | agents: updated_agents}

            {:node_capacity_changed, node, new_capacity} ->
              updated_nodes =
                Map.update(state.nodes, node, %{}, fn node_data ->
                  %{node_data | capacity: new_capacity}
                end)

              %{state | nodes: updated_nodes}

            _ ->
              state
          end
        end)

      # Update sync status
      updated_sync_status = %{state.sync_status | last_sync_timestamp: state_update.timestamp}

      %{List.last(processed_updates) | sync_status: updated_sync_status}
    end)

    :ok
  end

  def get_sync_status(_state) do
    Agent.get(__MODULE__, fn state ->
      {:ok, state.sync_status}
    end)
  end

  def handle_split_brain(split_brain_event, _state) do
    Agent.update(__MODULE__, fn state ->
      # Determine which partition has quorum (more coordinators)
      partitioned_count = length(split_brain_event.partitioned_nodes)
      isolated_count = length(split_brain_event.isolated_nodes)

      active_partition =
        if partitioned_count >= isolated_count do
          split_brain_event.partitioned_nodes
        else
          split_brain_event.isolated_nodes
        end

      partition_status = %{
        active_partition: active_partition,
        quorum_achieved: true,
        isolated_nodes: split_brain_event.isolated_nodes,
        partition_timestamp: split_brain_event.partition_timestamp
      }

      updated_sync_status = %{state.sync_status | partition_status: partition_status}

      %{state | sync_status: updated_sync_status}
    end)

    :ok
  end

  def get_partition_status(_state) do
    Agent.get(__MODULE__, fn state ->
      {:ok, state.sync_status.partition_status}
    end)
  end

  def resolve_state_conflicts(conflict_scenario, _state) do
    Agent.get(__MODULE__, fn _state ->
      # Simple conflict resolution: latest timestamp wins
      all_updates = conflict_scenario.node_a_updates ++ conflict_scenario.node_b_updates

      # Group by operation type and target
      grouped_updates =
        Enum.group_by(all_updates, fn update ->
          case update do
            {:agent_started, agent_id, _node, _timestamp} ->
              {:agent_started, agent_id}

            {:agent_capacity_updated, agent_id, _capacity, _timestamp} ->
              {:agent_capacity, agent_id}

            _ ->
              :other
          end
        end)

      # Resolve conflicts by taking latest timestamp
      resolved_updates =
        Enum.flat_map(grouped_updates, fn {_key, updates} ->
          case updates do
            [single_update] ->
              [single_update]

            multiple_updates ->
              # For conflicts, prefer the update with later timestamp
              latest =
                Enum.max_by(multiple_updates, fn update ->
                  case update do
                    {_, _, _, timestamp} -> timestamp
                    {_, _, timestamp} -> timestamp
                    _ -> 0
                  end
                end)

              [latest]
          end
        end)

      conflicts_detected =
        Enum.count(grouped_updates, fn {_key, updates} -> length(updates) > 1 end)

      resolution = %{
        conflicts_detected: conflicts_detected,
        resolution_strategy: :latest_timestamp,
        resolved_updates: resolved_updates
      }

      {:ok, resolution}
    end)
  end

  # Load balancing and health monitoring

  def update_node_load(node, load, _state) do
    Agent.update(__MODULE__, fn state ->
      updated_nodes =
        Map.update(state.nodes, node, %{}, fn node_data ->
          %{node_data | current_load: load}
        end)

      %{state | nodes: updated_nodes}
    end)

    :ok
  end

  def analyze_cluster_load(_state) do
    Agent.get(__MODULE__, fn state ->
      overloaded_nodes =
        state.nodes
        |> Enum.filter(fn {_node, info} ->
          info.status == :active and info.current_load > 80
        end)
        |> Enum.map(fn {node, info} ->
          %{
            node: node,
            current_load: info.current_load,
            capacity: info.capacity,
            recommended_action: :migrate_agents
          }
        end)

      underutilized_nodes =
        state.nodes
        |> Enum.filter(fn {_node, info} ->
          info.status == :active and info.current_load < 30
        end)
        |> Enum.map(fn {node, info} ->
          %{
            node: node,
            current_load: info.current_load,
            capacity: info.capacity,
            recommended_action: :accept_migrations
          }
        end)

      optimization_plan = %{
        overloaded_nodes: overloaded_nodes,
        underutilized_nodes: underutilized_nodes,
        balance_score: calculate_balance_score(state.nodes),
        recommended_migrations: []
      }

      {:ok, optimization_plan}
    end)
  end

  def update_node_health(health_update, _state) do
    Agent.update(__MODULE__, fn state ->
      current_health =
        Map.get(state.health_metrics, health_update.node, %{
          memory_usage: 0,
          cpu_usage: 0,
          alerts: [],
          last_updated: 0
        })

      # Update specific metric
      updated_health = Map.put(current_health, health_update.metric, health_update.value)
      updated_health = %{updated_health | last_updated: health_update.timestamp}

      # Generate alerts for critical values
      alerts = generate_alerts(health_update, current_health.alerts)
      updated_health = %{updated_health | alerts: alerts}

      updated_health_metrics = Map.put(state.health_metrics, health_update.node, updated_health)
      %{state | health_metrics: updated_health_metrics}
    end)

    :ok
  end

  def get_cluster_health(_state) do
    Agent.get(__MODULE__, fn state ->
      nodes_health =
        Enum.map(state.nodes, fn {node, node_info} ->
          health_data =
            Map.get(state.health_metrics, node, %{
              memory_usage: 0,
              cpu_usage: 0,
              alerts: [],
              last_updated: 0
            })

          health_status = determine_health_status(health_data)

          %{
            node: node,
            status: node_info.status,
            health_status: health_status,
            memory_usage: health_data.memory_usage,
            cpu_usage: health_data.cpu_usage,
            alerts: health_data.alerts,
            last_updated: health_data.last_updated
          }
        end)

      cluster_health = %{
        nodes: nodes_health,
        overall_status: calculate_overall_health(nodes_health),
        critical_alerts: count_critical_alerts(nodes_health)
      }

      {:ok, cluster_health}
    end)
  end

  # Event processing

  def process_coordination_event(event, _state) do
    Agent.get_and_update(__MODULE__, fn state ->
      case process_event(event, state) do
        {:ok, updated_state} ->
          coordination_event = %{
            type: elem(event, 0),
            data: event,
            timestamp: get_event_timestamp(event),
            processed: true
          }

          updated_log = [coordination_event | state.event_log]
          final_state = %{updated_state | event_log: updated_log}

          {:ok, final_state}

        {:error, reason} ->
          coordination_event = %{
            type: elem(event, 0),
            data: event,
            timestamp: get_event_timestamp(event),
            processed: false,
            error: reason
          }

          updated_log = [coordination_event | state.event_log]
          final_state = %{state | event_log: updated_log}

          {{:error, reason}, final_state}
      end
    end)
  end

  def get_coordination_log(_state) do
    Agent.get(__MODULE__, fn state ->
      processed_events = Enum.sort_by(state.event_log, & &1.timestamp)

      log_info = %{
        processed_events: processed_events,
        total_events: length(state.event_log),
        failed_events: Enum.count(state.event_log, fn event -> not event.processed end)
      }

      {:ok, log_info}
    end)
  end

  # Helper functions

  defp calculate_balance_score(nodes) do
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

  defp generate_alerts(health_update, existing_alerts) do
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

  defp determine_health_status(health_data) do
    critical_alerts = Enum.count(health_data.alerts, fn alert -> alert.severity == :critical end)
    high_alerts = Enum.count(health_data.alerts, fn alert -> alert.severity == :high end)

    cond do
      critical_alerts > 0 -> :critical
      high_alerts > 0 -> :warning
      health_data.memory_usage > 70 or health_data.cpu_usage > 70 -> :caution
      true -> :healthy
    end
  end

  defp calculate_overall_health(nodes_health) do
    critical_count = Enum.count(nodes_health, fn node -> node.health_status == :critical end)
    warning_count = Enum.count(nodes_health, fn node -> node.health_status == :warning end)

    cond do
      critical_count > 0 -> :critical
      warning_count > length(nodes_health) / 2 -> :degraded
      warning_count > 0 -> :warning
      true -> :healthy
    end
  end

  defp count_critical_alerts(nodes_health) do
    Enum.sum(
      Enum.map(nodes_health, fn node ->
        Enum.count(node.alerts, fn alert -> alert.severity == :critical end)
      end)
    )
  end

  defp process_event(event, state) do
    case event do
      {:node_join, node, node_info, _timestamp} ->
        # Process node join directly without calling external function
        node_data = %{
          node: node,
          status: :active,
          capacity: node_info.capacity,
          current_load: 0,
          capabilities: Map.get(node_info, :capabilities, []),
          resources: Map.get(node_info, :resources, %{}),
          joined_at: System.system_time(:millisecond),
          agent_count: 0
        }

        updated_nodes = Map.put(state.nodes, node, node_data)
        updated_state = %{state | nodes: updated_nodes}
        {:ok, updated_state}

      {:agent_start_request, agent_id, agent_info, _timestamp} ->
        # Simulate agent assignment logic
        {:ok, state}

      {:agent_assigned, agent_id, node, _timestamp} ->
        # Process agent assignment directly
        agent_data = %{
          id: agent_id,
          node: node,
          type: :worker,
          priority: :normal,
          resources: %{},
          assigned_at: System.system_time(:millisecond)
        }

        updated_agents = Map.put(state.agents, agent_id, agent_data)

        # Update node agent count
        updated_nodes =
          Map.update(state.nodes, node, %{}, fn node_data ->
            %{node_data | agent_count: node_data.agent_count + 1}
          end)

        updated_state = %{state | agents: updated_agents, nodes: updated_nodes}
        {:ok, updated_state}

      {:node_capacity_update, node, capacity, _timestamp} ->
        # Update node capacity directly
        updated_nodes =
          Map.update(state.nodes, node, %{}, fn node_data ->
            %{node_data | capacity: capacity}
          end)

        updated_state = %{state | nodes: updated_nodes}
        {:ok, updated_state}

      {:redistribution_suggested, _nodes, _timestamp} ->
        {:ok, state}

      {:invalid_event, _data, _timestamp} ->
        {:error, :invalid_event_type}

      _ ->
        {:error, :unknown_event_type}
    end
  end

  defp get_event_timestamp(event) do
    case event do
      {_type, _arg1, _arg2, _arg3, timestamp: timestamp} -> timestamp
      {_type, _arg1, _arg2, timestamp: timestamp} -> timestamp
      {_type, _arg1, timestamp: timestamp} -> timestamp
      _ -> System.system_time(:millisecond)
    end
  end
end
