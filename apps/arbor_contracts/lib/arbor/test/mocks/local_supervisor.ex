defmodule Arbor.Test.Mocks.LocalSupervisor do
  @moduledoc """
  TEST MOCK - DO NOT USE IN PRODUCTION

  Local, non-distributed supervisor for testing supervisor operations.
  This mock simulates distributed supervisor behavior in a single node.

  @warning This is a TEST MOCK - not distributed!
  """

  @behaviour Arbor.Contracts.Cluster.Supervisor
  use GenServer

  require Logger

  defstruct [
    :agents,
    :specs,
    :monitors,
    :event_handlers,
    :restart_counts
  ]

  @type state() :: %__MODULE__{
          agents: map(),
          specs: map(),
          monitors: map(),
          event_handlers: map(),
          restart_counts: map()
        }

  # Client API

  @doc """
  Starts the LocalSupervisor GenServer.
  """
  @spec start_link() :: GenServer.on_start()
  def start_link() do
    start_link([])
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Clears all supervised agents.
  """
  @spec clear() :: :ok
  def clear() do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Register an agent that has already started.
  Used for compatibility with AgentBehavior.
  """
  @spec register_agent(pid(), binary(), map()) :: {:ok, pid()} | {:error, atom()}
  def register_agent(pid, agent_id, agent_metadata) do
    GenServer.call(__MODULE__, {:register_agent, pid, agent_id, agent_metadata})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      agents: %{},
      specs: %{},
      monitors: %{},
      event_handlers: %{},
      restart_counts: %{}
    }

    {:ok, state}
  end

  # All handle_call/3 clauses grouped together

  @impl true
  def handle_call(:clear, _from, state) do
    # Stop all agents
    for {_id, pid} <- state.agents do
      Process.exit(pid, :shutdown)
    end

    # Clear state
    new_state = %__MODULE__{
      agents: %{},
      specs: %{},
      monitors: %{},
      event_handlers: %{},
      restart_counts: %{}
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:register_agent, pid, agent_id, _agent_metadata}, _from, state) do
    # Check if the agent spec exists
    case Map.get(state.specs, agent_id) do
      nil ->
        Logger.error("Could not find spec for agent #{agent_id} during registration.")
        {:reply, {:error, :spec_not_found}, state}

      _spec ->
        # Check if process is alive
        if Process.alive?(pid) do
          # Agent is already tracked by start_child, just acknowledge
          {:reply, {:ok, pid}, state}
        else
          Logger.warning("Attempted to register a non-alive process",
            pid: pid,
            agent_id: agent_id
          )

          {:reply, {:error, :process_not_alive}, state}
        end
    end
  end

  @impl true
  def handle_call({:start_child, spec}, _from, state) do
    agent_id = spec.id

    case Map.get(state.agents, agent_id) do
      nil ->
        # Start the agent process
        case start_agent_process(spec) do
          {:ok, pid} ->
            # Monitor the process
            ref = Process.monitor(pid)

            new_agents = Map.put(state.agents, agent_id, pid)
            new_specs = Map.put(state.specs, agent_id, spec)
            new_monitors = Map.put(state.monitors, agent_id, ref)

            # Initialize restart count if this is a new agent
            new_restart_counts =
              if Map.has_key?(state.restart_counts, agent_id) do
                state.restart_counts
              else
                Map.put(state.restart_counts, agent_id, 0)
              end

            new_state = %{
              state
              | agents: new_agents,
                specs: new_specs,
                monitors: new_monitors,
                restart_counts: new_restart_counts
            }

            # Trigger event handler if registered
            if handler = Map.get(state.event_handlers, :agent_started) do
              spawn(fn -> handler.({:agent_started, agent_id, %{pid: pid, spec: spec}}) end)
            end

            {:reply, {:ok, pid}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _pid ->
        {:reply, {:error, :agent_already_started}, state}
    end
  end

  @impl true
  def handle_call({:terminate_child, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :agent_not_found}, state}

      pid ->
        # Stop the process gracefully
        Process.exit(pid, :shutdown)

        # Trigger event handler if registered
        if handler = Map.get(state.event_handlers, :agent_stopped) do
          spawn(fn -> handler.({:agent_stopped, agent_id, %{reason: :user_requested}}) end)
        end

        # Wait a bit for cleanup
        Process.sleep(10)

        # Clean up immediately instead of waiting for handle_info
        monitor_ref = Map.get(state.monitors, agent_id)
        if monitor_ref, do: Process.demonitor(monitor_ref, [:flush])

        new_agents = Map.delete(state.agents, agent_id)
        new_monitors = Map.delete(state.monitors, agent_id)

        new_state = %{state | agents: new_agents, monitors: new_monitors}

        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:restart_child, agent_id}, _from, state) do
    case Map.get(state.specs, agent_id) do
      nil ->
        {:reply, {:error, :agent_not_found}, state}

      spec ->
        # Stop existing process if any
        if pid = Map.get(state.agents, agent_id) do
          Process.exit(pid, :shutdown)
        end

        # Start new process
        case start_agent_process(spec) do
          {:ok, new_pid} ->
            # Monitor the new process
            ref = Process.monitor(new_pid)

            new_agents = Map.put(state.agents, agent_id, new_pid)
            new_monitors = Map.put(state.monitors, agent_id, ref)

            # Increment restart count for this agent
            current_count = Map.get(state.restart_counts, agent_id, 0)
            new_restart_counts = Map.put(state.restart_counts, agent_id, current_count + 1)

            new_state = %{
              state
              | agents: new_agents,
                monitors: new_monitors,
                restart_counts: new_restart_counts
            }

            {:reply, {:ok, new_pid}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call(:which_children, _from, state) do
    children =
      Enum.map(state.agents, fn {id, pid} ->
        spec = Map.get(state.specs, id)
        {id, pid, :worker, [spec.module]}
      end)

    {:reply, children, state}
  end

  @impl true
  def handle_call(:count_children, _from, state) do
    count = %{
      specs: map_size(state.specs),
      active: map_size(state.agents),
      supervisors: 0,
      workers: map_size(state.agents)
    }

    {:reply, count, state}
  end

  @impl true
  def handle_call(:count_agents, _from, state) do
    {:reply, map_size(state.agents), state}
  end

  @impl true
  def handle_call(:health_metrics, _from, state) do
    metrics = %{
      total_agents: map_size(state.agents),
      running_agents: map_size(state.agents),
      restarting_agents: 0,
      failed_agents: 0,
      nodes: [node()],
      restart_intensity: calculate_restart_intensity(state),
      memory_usage: :erlang.memory(:total)
    }

    {:reply, {:ok, metrics}, state}
  end

  @impl true
  def handle_call(:list_agents, _from, state) do
    agents =
      Enum.map(state.agents, fn {id, pid} ->
        spec = Map.get(state.specs, id)

        %{
          id: id,
          pid: pid,
          node: node(),
          status: :running,
          module: spec.module,
          restart_count: Map.get(state.restart_counts, id, 0)
        }
      end)

    {:reply, {:ok, agents}, state}
  end

  @impl true
  def handle_call({:set_event_handler, event_type, callback}, _from, state) do
    new_handlers = Map.put(state.event_handlers, event_type, callback)
    {:reply, :ok, %{state | event_handlers: new_handlers}}
  end

  @impl true
  def handle_call({:get_agent_info, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :agent_not_found}, state}

      pid ->
        spec = Map.get(state.specs, agent_id)

        info = %{
          id: agent_id,
          pid: pid,
          node: node(),
          status: :running,
          restart_count: Map.get(state.restart_counts, agent_id, 0),
          metadata: Map.get(spec, :metadata, %{}),
          spec: spec,
          memory: get_process_memory(pid),
          message_queue_len: get_message_queue_len(pid),
          restart_history: []
        }

        {:reply, {:ok, info}, state}
    end
  end

  @impl true
  def handle_call({:update_agent_spec, agent_id, updates}, _from, state) do
    case Map.get(state.specs, agent_id) do
      nil ->
        {:reply, {:error, :agent_not_found}, state}

      spec ->
        updated_spec = Map.merge(spec, updates)
        new_specs = Map.put(state.specs, agent_id, updated_spec)
        {:reply, :ok, %{state | specs: new_specs}}
    end
  end

  @impl true
  def handle_call({:extract_agent_state, agent_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :agent_not_found}, state}

      pid ->
        # Try to extract state from the agent
        # The agent should respond to :get_state if it supports state extraction
        try do
          case GenServer.call(pid, :get_state, 5000) do
            agent_state when is_map(agent_state) ->
              {:reply, {:ok, agent_state}, state}

            other ->
              # Return whatever the agent provides
              {:reply, {:ok, other}, state}
          end
        catch
          :exit, {:timeout, _} ->
            {:reply, {:error, :timeout}, state}

          :exit, {:noproc, _} ->
            {:reply, {:error, :agent_not_found}, state}

          _, _ ->
            # If agent doesn't support get_state, return a default
            {:reply, {:ok, %{agent_id: agent_id, state: :unknown}}, state}
        end
    end
  end

  @impl true
  def handle_call({:restore_agent_state, agent_id, agent_state}, _from, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:reply, {:error, :agent_not_found}, state}

      _pid ->
        # For testing, just acknowledge the restore
        {:reply, {:ok, agent_state}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    # Find the agent_id for this monitor reference
    {agent_id, _} =
      Enum.find(state.monitors, fn {_id, monitor_ref} -> monitor_ref == ref end) ||
        {nil, nil}

    if agent_id do
      Logger.info(
        "Agent #{agent_id} (#{inspect(pid)}) terminated with reason: #{inspect(reason)}"
      )

      # Clean up agent from state
      new_agents = Map.delete(state.agents, agent_id)
      new_monitors = Map.delete(state.monitors, agent_id)

      # Trigger event handler if registered
      if handler = Map.get(state.event_handlers, :agent_stopped) do
        spawn(fn -> handler.({:agent_stopped, agent_id, %{reason: reason, pid: pid}}) end)
      end

      new_state = %{state | agents: new_agents, monitors: new_monitors}
      {:noreply, new_state}
    else
      # Unknown monitor reference, just ignore
      {:noreply, state}
    end
  end

  # Private helpers

  defp start_agent_process(spec) do
    # Extract args, ensuring they're in the correct format
    base_args =
      case spec.args do
        [initial_state: state] -> [initial_state: state]
        {:initial_state, state} -> [initial_state: state]
        _ when is_list(spec.args) -> spec.args
        _ -> []
      end

    # Add agent_id and metadata to args for AgentBehavior compatibility
    args_with_agent_info =
      Keyword.merge(base_args,
        agent_id: spec.id,
        agent_metadata: Map.get(spec, :metadata, %{})
      )

    # Use the module specified in the spec
    module = Map.get(spec, :module)

    # For testing, start the specified agent module (not linked to avoid test interference)
    case GenServer.start(module, args_with_agent_info) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # Helper functions for public API
  @spec start_child(map()) :: {:ok, pid()} | {:error, term()}
  def start_child(spec) do
    GenServer.call(__MODULE__, {:start_child, spec})
  end

  @spec terminate_child(binary()) :: :ok | {:error, term()}
  def terminate_child(agent_id) do
    GenServer.call(__MODULE__, {:terminate_child, agent_id})
  end

  @spec restart_child(binary()) :: {:ok, pid()} | {:error, term()}
  def restart_child(agent_id) do
    GenServer.call(__MODULE__, {:restart_child, agent_id})
  end

  @spec which_children() :: list()
  def which_children() do
    GenServer.call(__MODULE__, :which_children)
  end

  @spec count_children() :: map()
  def count_children() do
    GenServer.call(__MODULE__, :count_children)
  end

  # Implement the Arbor.Contracts.Cluster.Supervisor behaviour

  @impl Arbor.Contracts.Cluster.Supervisor
  def start_service(config) when is_map(config) do
    # Convert map to keyword list for start_link
    opts = Map.to_list(config)
    start_link(opts)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def stop_service(_reason) do
    :ok
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def get_status() do
    {:ok,
     %{
       status: :healthy,
       nodes: [node()],
       agent_count: GenServer.call(__MODULE__, :count_agents)
     }}
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def start_agent(agent_spec) do
    start_child(agent_spec)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def stop_agent(agent_id, _timeout) do
    terminate_child(agent_id)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def restart_agent(agent_id) do
    restart_child(agent_id)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def get_agent_info(agent_id) do
    GenServer.call(__MODULE__, {:get_agent_info, agent_id})
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def list_agents() do
    GenServer.call(__MODULE__, :list_agents)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def restore_agent(agent_id) do
    restart_child(agent_id)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def update_agent_spec(agent_id, updates) do
    GenServer.call(__MODULE__, {:update_agent_spec, agent_id, updates})
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def health_metrics() do
    GenServer.call(__MODULE__, :health_metrics)
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def set_event_handler(event_type, callback) do
    GenServer.call(__MODULE__, {:set_event_handler, event_type, callback})
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def extract_agent_state(agent_id) do
    GenServer.call(__MODULE__, {:extract_agent_state, agent_id})
  end

  @impl Arbor.Contracts.Cluster.Supervisor
  def restore_agent_state(agent_id, state) do
    GenServer.call(__MODULE__, {:restore_agent_state, agent_id, state})
  end

  # Private helper functions moved below

  defp get_process_memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> bytes
      nil -> 0
    end
  end

  defp get_message_queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len
      nil -> 0
    end
  end

  defp calculate_restart_intensity(%__MODULE__{restart_counts: counts}) do
    # Simple calculation - total restarts across all agents
    # For testing, just return a positive value if there have been restarts
    total_restarts = counts |> Map.values() |> Enum.sum()
    if total_restarts > 0, do: total_restarts / 1.0, else: 0.0
  end
end
