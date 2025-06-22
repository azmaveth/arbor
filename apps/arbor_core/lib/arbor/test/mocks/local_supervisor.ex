defmodule Arbor.Test.Mocks.LocalSupervisor do
  @moduledoc """
  MOCK implementation of cluster supervisor for single-node testing.

  This provides a local-only implementation of the Arbor.Contracts.Cluster.Supervisor
  behaviour for unit testing distributed supervision logic without requiring actual clustering.

  IMPORTANT: This is a MOCK - replace with Horde for distributed operation!
  """

  @behaviour Arbor.Contracts.Cluster.Supervisor

  use Agent

  alias Arbor.Core.ClusterRegistry

  defstruct [
    :agents,
    :event_handlers,
    :restart_counts,
    :node_assignments
  ]

  @type state :: %__MODULE__{
          agents: %{binary() => agent_record()},
          event_handlers: %{atom() => [function()]},
          restart_counts: %{binary() => non_neg_integer()},
          node_assignments: %{binary() => node()}
        }

  @type agent_record :: %{
          spec: map(),
          pid: pid(),
          status: :running | :stopped | :restarting,
          started_at: integer(),
          restart_count: non_neg_integer(),
          restart_history: [restart_event()],
          metadata: map()
        }

  @type restart_event :: %{
          timestamp: integer(),
          reason: term()
        }

  # Client API

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(
      fn ->
        %__MODULE__{
          agents: %{},
          event_handlers: %{},
          restart_counts: %{},
          node_assignments: %{}
        }
      end,
      name: __MODULE__
    )
  end

  def clear do
    Agent.update(__MODULE__, fn _state ->
      %__MODULE__{
        agents: %{},
        event_handlers: %{},
        restart_counts: %{},
        node_assignments: %{}
      }
    end)
  end

  @spec init(any()) :: {:ok, state()}
  def init(_opts) do
    state = %__MODULE__{
      agents: %{},
      event_handlers: %{},
      restart_counts: %{},
      node_assignments: %{}
    }

    {:ok, state}
  end

  @spec start_supervisor(any()) :: {:ok, state()}
  def start_supervisor(_opts) do
    state = %__MODULE__{
      agents: %{},
      event_handlers: %{},
      restart_counts: %{},
      node_assignments: %{}
    }

    {:ok, state}
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def start_agent(agent_spec) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.agents, agent_spec.id) do
        nil ->
          # Start the appropriate process based on the module
          module = Map.get(agent_spec, :module, Arbor.Test.Mocks.TestAgent)
          {:ok, pid} = module.start_link(agent_spec.args)

          agent_record = %{
            spec: agent_spec,
            pid: pid,
            status: :running,
            started_at: System.system_time(:millisecond),
            restart_count: 0,
            restart_history: [],
            metadata: Map.get(agent_spec, :metadata, %{})
          }

          # Register the agent in ClusterRegistry
          metadata = Map.get(agent_spec, :metadata, %{})
          ClusterRegistry.register_agent(agent_spec.id, pid, metadata)

          updated_agents = Map.put(state.agents, agent_spec.id, agent_record)
          updated_state = %{state | agents: updated_agents}

          # Trigger start event
          trigger_event(updated_state, :agent_started, agent_spec.id, %{pid: pid})

          {{:ok, pid}, updated_state}

        _existing ->
          {{:error, :agent_already_started}, state}
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def stop_agent(agent_id, _timeout) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.agents, agent_id) do
        nil ->
          {{:error, :agent_not_found}, state}

        agent_record ->
          # Stop the agent process
          if Process.alive?(agent_record.pid) do
            Process.exit(agent_record.pid, :normal)
          end

          # Unregister from ClusterRegistry
          ClusterRegistry.unregister_agent(agent_id)

          # Remove from agents map
          updated_agents = Map.delete(state.agents, agent_id)
          updated_state = %{state | agents: updated_agents}

          # Trigger stop event
          trigger_event(updated_state, :agent_stopped, agent_id, %{
            pid: agent_record.pid,
            reason: :normal
          })

          {:ok, updated_state}
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def restart_agent(agent_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.agents, agent_id) do
        nil ->
          {{:error, :agent_not_found}, state}

        agent_record ->
          # Stop existing process
          if Process.alive?(agent_record.pid) do
            Process.exit(agent_record.pid, :normal)
          end

          # Start new process
          module = Map.get(agent_record.spec, :module, Arbor.Test.Mocks.TestAgent)
          {:ok, new_pid} = module.start_link(agent_record.spec.args)

          # Unregister old entry and register new PID
          ClusterRegistry.unregister_agent(agent_id)
          metadata = Map.get(agent_record.spec, :metadata, %{})
          ClusterRegistry.register_agent(agent_id, new_pid, metadata)

          # Update restart tracking
          restart_event = %{
            timestamp: System.system_time(:millisecond),
            reason: :restart
          }

          updated_record = %{
            agent_record
            | pid: new_pid,
              status: :running,
              restart_count: agent_record.restart_count + 1,
              restart_history: [restart_event | agent_record.restart_history]
          }

          updated_agents = Map.put(state.agents, agent_id, updated_record)
          updated_state = %{state | agents: updated_agents}

          # Trigger restart event
          trigger_event(updated_state, :agent_restarted, agent_id, %{
            old_pid: agent_record.pid,
            new_pid: new_pid,
            restart_count: updated_record.restart_count
          })

          {{:ok, new_pid}, updated_state}
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def list_agents() do
    Agent.get(__MODULE__, fn state ->
      agents =
        Enum.map(state.agents, fn {agent_id, record} ->
          %{
            id: agent_id,
            pid: record.pid,
            node: Map.get(state.node_assignments, agent_id, node()),
            status: record.status,
            restart_count: record.restart_count,
            started_at: record.started_at,
            metadata: record.metadata
          }
        end)

      {:ok, agents}
    end)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def get_agent_info(agent_id) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.agents, agent_id) do
        nil ->
          {:error, :agent_not_found}

        record ->
          # Get process information
          {memory, message_queue_len} =
            if Process.alive?(record.pid) do
              {:memory, memory} = Process.info(record.pid, :memory)
              {:message_queue_len, queue_len} = Process.info(record.pid, :message_queue_len)
              {memory, queue_len}
            else
              {0, 0}
            end

          info = %{
            id: agent_id,
            pid: record.pid,
            node: Map.get(state.node_assignments, agent_id, node()),
            status: record.status,
            restart_count: record.restart_count,
            started_at: record.started_at,
            metadata: record.metadata,
            spec: record.spec,
            restart_history: record.restart_history,
            memory: memory,
            message_queue_len: message_queue_len
          }

          {:ok, info}
      end
    end)
  end

  @spec migrate_agent(String.t(), node()) :: {:ok, map()} | {:error, atom()}
  def migrate_agent(agent_id, target_node) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.agents, agent_id) do
        nil ->
          {{:error, :agent_not_found}, state}

        agent_record ->
          # Simulate node availability check
          available_nodes = [node(), :test@otherhost, :test@anotherhost]

          if target_node in available_nodes do
            # Stop current process
            if Process.alive?(agent_record.pid) do
              Process.exit(agent_record.pid, :normal)
            end

            # Start new process (simulating cross-node migration)
            {:ok, new_pid} = Arbor.Test.Mocks.TestAgent.start_link(agent_record.spec.args)

            # Update node assignment
            updated_assignments = Map.put(state.node_assignments, agent_id, target_node)

            # Update agent record
            updated_record = %{agent_record | pid: new_pid, status: :running}

            updated_agents = Map.put(state.agents, agent_id, updated_record)

            updated_state = %{
              state
              | agents: updated_agents,
                node_assignments: updated_assignments
            }

            # Trigger migration event
            trigger_event(updated_state, :agent_migrated, agent_id, %{
              old_pid: agent_record.pid,
              new_pid: new_pid,
              old_node: node(),
              new_node: target_node
            })

            {{:ok, new_pid}, updated_state}
          else
            {{:error, :node_not_available}, state}
          end
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def update_agent_spec(agent_id, updates) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.agents, agent_id) do
        nil ->
          {{:error, :agent_not_found}, state}

        agent_record ->
          # Update the spec with new values
          updated_spec = Map.merge(agent_record.spec, updates)

          updated_record = %{agent_record | spec: updated_spec}
          updated_agents = Map.put(state.agents, agent_id, updated_record)
          updated_state = %{state | agents: updated_agents}

          {:ok, updated_state}
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def health_metrics() do
    Agent.get(__MODULE__, fn state ->
      agents = Map.values(state.agents)

      total_agents = length(agents)
      running_agents = Enum.count(agents, &(&1.status == :running))
      restarting_agents = Enum.count(agents, &(&1.status == :restarting))
      failed_agents = total_agents - running_agents - restarting_agents

      # Calculate restart intensity (restarts per minute)
      now = System.system_time(:millisecond)
      one_minute_ago = now - 60_000

      recent_restarts =
        agents
        |> Enum.flat_map(& &1.restart_history)
        |> Enum.count(fn event -> event.timestamp > one_minute_ago end)

      # Calculate total memory usage
      total_memory =
        agents
        |> Enum.map(fn record ->
          if Process.alive?(record.pid) do
            {:memory, memory} = Process.info(record.pid, :memory)
            memory
          else
            0
          end
        end)
        |> Enum.sum()

      # Node distribution
      nodes =
        state.node_assignments
        |> Map.values()
        |> Enum.uniq()
        |> case do
          [] -> [node()]
          nodes -> nodes
        end

      health = %{
        total_agents: total_agents,
        running_agents: running_agents,
        restarting_agents: restarting_agents,
        failed_agents: failed_agents,
        nodes: nodes,
        restart_intensity: recent_restarts,
        memory_usage: total_memory
      }

      {:ok, health}
    end)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def set_event_handler(event_type, callback) do
    Agent.update(__MODULE__, fn state ->
      current_handlers = Map.get(state.event_handlers, event_type, [])
      updated_handlers = [callback | current_handlers]
      updated_event_handlers = Map.put(state.event_handlers, event_type, updated_handlers)

      %{state | event_handlers: updated_event_handlers}
    end)

    :ok
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def handle_agent_handoff(agent_id, operation, state_data) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.agents, agent_id) do
        nil ->
          {:error, :agent_not_found}

        agent_record ->
          case operation do
            :handoff ->
              # Extract agent state
              if Process.alive?(agent_record.pid) do
                agent_state = GenServer.call(agent_record.pid, :get_state)
                {:ok, agent_state}
              else
                {:ok, %{}}
              end

            :takeover ->
              # Restore agent state
              if Process.alive?(agent_record.pid) do
                GenServer.cast(agent_record.pid, {:set_state, state_data})
                {:ok, state_data}
              else
                {:error, :agent_not_alive}
              end
          end
      end
    end)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def restore_agent(agent_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.agents, agent_id) do
        nil ->
          {{:error, :agent_not_found}, state}

        agent_record ->
          # Stop existing process
          if Process.alive?(agent_record.pid) do
            Process.exit(agent_record.pid, :normal)
          end

          # Start new process with state recovery
          module = Map.get(agent_record.spec, :module, Arbor.Test.Mocks.TestAgent)
          {:ok, new_pid} = module.start_link(agent_record.spec.args)

          # Unregister old entry and register new PID
          ClusterRegistry.unregister_agent(agent_id)
          metadata = Map.get(agent_record.spec, :metadata, %{})
          ClusterRegistry.register_agent(agent_id, new_pid, metadata)

          # Update restart tracking
          restart_event = %{
            timestamp: System.system_time(:millisecond),
            reason: :restore
          }

          updated_record = %{
            agent_record
            | pid: new_pid,
              status: :running,
              restart_count: agent_record.restart_count + 1,
              restart_history: [restart_event | agent_record.restart_history]
          }

          updated_agents = Map.put(state.agents, agent_id, updated_record)
          updated_state = %{state | agents: updated_agents}

          {{:ok, new_pid}, updated_state}
      end
    end)
  end

  # Additional functions for ClusterSupervisor compatibility

  @spec extract_agent_state(String.t(), any()) :: {:ok, any()} | {:error, atom()}
  def extract_agent_state(agent_id, _state \\ nil) do
    handle_agent_handoff(agent_id, :handoff, nil)
  end

  @spec restore_agent_state(String.t(), any(), any()) :: {:ok, map()} | {:error, atom()}
  def restore_agent_state(agent_id, state_data, _state \\ nil) do
    handle_agent_handoff(agent_id, :takeover, state_data)
  end

  # Helper functions

  defp trigger_event(state, event_type, agent_id, details) do
    handlers = Map.get(state.event_handlers, event_type, [])

    for handler <- handlers do
      try do
        handler.({event_type, agent_id, details})
      rescue
        # Ignore handler errors in tests
        _ -> :ok
      end
    end
  end
end
