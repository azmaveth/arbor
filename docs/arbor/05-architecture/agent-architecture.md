# Arbor Agent Architecture
## Two-Tiered Agent System with OTP Supervision

### Executive Summary

This document outlines Arbor's comprehensive agent architecture, implementing a two-tiered agent system that separates coordination concerns from specialized work execution. The architecture leverages Elixir/OTP patterns for fault tolerance, scalability, and clean separation of concerns.

**Key Architectural Principles:**
- 🎯 **Two-Tiered Taxonomy**: Coordinator agents manage sessions, worker agents execute tasks
- 🔄 **Per-Session Isolation**: Each chat session runs as an independent GenServer
- 🤖 **Dynamic Worker Spawning**: Specialized agents created on-demand for specific tasks
- 📊 **Event-Driven Communication**: Phoenix.PubSub for real-time updates
- 🛡️ **Fault Tolerance**: OTP supervision trees ensure system resilience

---

## 1. Agent Taxonomy

### 1.1 Two-Tiered Agent Classification

```
┌─────────────────────────────────────────────────────────────┐
│                    Coordinator Agents                       │
│  (Long-lived, Stateful, Interactive)                      │
│                                                            │
│  • Session Agents - User chat sessions                    │
│  • Session Manager - Lifecycle coordination               │
│  • Agent Monitor - System observability                   │
└─────────────────────────────────────────────────────────────┘
                            │
                    Spawns & Manages
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                     Worker Agents                          │
│  (Task-specific, Temporary, Specialized)                  │
│                                                            │
│  • Tool Executor Agents - Heavy MCP operations           │
│  • Export Agents - Data export and reporting             │
│  • Maintenance Agents - System cleanup tasks             │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Agent Characteristics

| Agent Type | Coordinator | Worker |
|------------|-------------|---------|
| **Lifecycle** | Long-lived (hours/days) | Short-lived (seconds/minutes) |
| **State** | Stateful, maintains context | Stateless or minimal state |
| **Purpose** | Orchestration, user interaction | Specific task execution |
| **Spawning** | Started by application/user | Spawned by coordinators |
| **Supervision** | Direct supervision | Dynamic supervision |
| **Examples** | Session, Manager | Tool Executor, Export |

---

## 2. System Architecture

### 2.1 Complete Supervision Tree

```
Arbor.Application
├── Core Infrastructure
│   ├── Phoenix.PubSub (Event Broadcasting)
│   └── Registry (Process Discovery)
│
├── Coordinator Layer
│   ├── Arbor.SessionManager (Coordinator)
│   │   ├── Registry (Session Discovery)
│   │   └── DynamicSupervisor (Session Lifecycle)
│   │       └── Arbor.Session (Main Agents)
│   │
│   └── Arbor.AgentMonitor (System Observer)
│
└── Worker Layer (Arbor.AgentSupervisor)
    ├── Arbor.MaintenanceAgent (Singleton Worker)
    ├── Arbor.AgentPool (Resource Manager)
    ├── Arbor.ToolExecutorSupervisor
    │   └── Arbor.ToolExecutorAgent (Dynamic Workers)
    └── Arbor.ExportSupervisor
        └── Arbor.ExportAgent (Dynamic Workers)
```

### 2.2 Communication Patterns

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer                             │
│  ┌─────────────────┐              ┌───────────────────┐    │
│  │   TUI Client    │              │  Web UI (Phoenix) │    │
│  └─────────────────┘              └───────────────────┘    │
└─────────────────────────────────────────────────────────────┘
           │                                │
           │ Gateway API                    │ Phoenix Channels
           ▼                                ▼
┌─────────────────────────────────────────────────────────────┐
│                    Gateway API Layer                        │
│               Stateless API Functions                       │
└─────────────────────────────────────────────────────────────┘
           │
           │ GenServer calls/casts
           ▼
┌─────────────────────────────────────────────────────────────┐
│                 Coordinator Agent Layer                     │
│  ┌─────────────────┐  ┌─────────────┐  ┌─────────────────┐│
│  │ SessionManager  │  │   PubSub    │  │ Session Agents  ││
│  │  - Registry     │  │ (Events)    │  │ (Per-Session)   ││
│  │  - Lifecycle    │  │             │  │                 ││
│  └─────────────────┘  └─────────────┘  └─────────────────┘│
└─────────────────────────────────────────────────────────────┘
           │
           │ Spawns workers
           ▼
┌─────────────────────────────────────────────────────────────┐
│                   Worker Agent Layer                        │
│  ┌─────────────────┐  ┌─────────────┐  ┌─────────────────┐│
│  │   Agent Pool    │  │Tool Executor│  │ Export Agents   ││
│  │ (Rate Limiting) │  │  (Heavy IO) │  │ (Reporting)     ││
│  └─────────────────┘  └─────────────┘  └─────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Agent Lifecycle Management

### 3.1 Session Agent Lifecycle

```elixir
defmodule Arbor.Session do
  use GenServer
  
  defstruct [
    :session_id,
    :messages,
    :user_context,
    :mcp_servers,
    :llm_adapter,
    :current_state,  # :idle, :thinking, :awaiting_permission
    :stats,
    :config,
    :active_workers  # Track spawned worker agents
  ]
  
  # Lifecycle callbacks
  def init([session_id: session_id] ++ opts) do
    Process.flag(:trap_exit, true)  # Monitor worker agents
    
    {:ok, %__MODULE__{
      session_id: session_id,
      messages: [],
      current_state: :idle,
      active_workers: %{}
    }}
  end
  
  def terminate(reason, state) do
    # Clean up any active workers
    Enum.each(state.active_workers, fn {_id, pid} ->
      Process.exit(pid, :shutdown)
    end)
    
    broadcast_event(state.session_id, %SessionEnded{
      session_id: state.session_id,
      reason: reason
    })
  end
  
  # Worker management
  def handle_call({:spawn_worker, type, task_spec}, _from, state) do
    case spawn_worker_agent(type, task_spec, state) do
      {:ok, worker_id, worker_pid} ->
        new_workers = Map.put(state.active_workers, worker_id, worker_pid)
        {:reply, {:ok, worker_id}, %{state | active_workers: new_workers}}
        
      error ->
        {:reply, error, state}
    end
  end
  
  # Handle worker termination
  def handle_info({:EXIT, pid, reason}, state) do
    {worker_id, remaining} = pop_worker_by_pid(state.active_workers, pid)
    
    if worker_id do
      handle_worker_exit(worker_id, pid, reason, state)
    end
    
    {:noreply, %{state | active_workers: remaining}}
  end
end
```

### 3.2 Worker Agent Lifecycle

```elixir
defmodule Arbor.ToolExecutorAgent do
  use GenServer, restart: :temporary  # Don't restart on crash
  
  def start_link({session_id, task_spec}) do
    GenServer.start_link(__MODULE__, {session_id, task_spec})
  end
  
  def init({session_id, task_spec}) do
    # Link to parent session
    Process.link(get_session_pid(session_id))
    
    # Start work immediately
    send(self(), :execute)
    
    {:ok, %{
      session_id: session_id,
      task_spec: task_spec,
      started_at: DateTime.utc_now()
    }}
  end
  
  def handle_info(:execute, state) do
    result = execute_task(state.task_spec)
    
    # Notify parent session
    notify_completion(state.session_id, result)
    
    # Terminate gracefully
    {:stop, :normal, state}
  end
end
```

---

## 4. State Management

### 4.1 Coordinator State Patterns

```elixir
defmodule Arbor.SessionManager do
  use GenServer
  
  @registry_name Arbor.SessionRegistry
  
  def init(_opts) do
    # ETS for fast lookups
    :ets.new(:session_metadata, [:named_table, :public, :set])
    
    {:ok, %{
      active_sessions: %{},
      worker_tracking: %{},
      stats: init_stats()
    }}
  end
  
  # Via tuple for reliable process addressing
  def via_tuple(session_id) do
    {:via, Registry, {@registry_name, session_id}}
  end
  
  # Session discovery
  def get_session_pid(session_id) do
    case Registry.lookup(@registry_name, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
  
  # Atomic state updates
  def handle_call({:update_session_state, session_id, update_fn}, _from, state) do
    case get_session_pid(session_id) do
      {:ok, pid} ->
        result = GenServer.call(pid, {:update_state, update_fn})
        {:reply, result, state}
        
      error ->
        {:reply, error, state}
    end
  end
end
```

### 4.2 Worker State Patterns

Worker agents maintain minimal state and rely on parent coordinators for context:

```elixir
defmodule Arbor.ExportAgent do
  use GenServer, restart: :temporary
  
  defstruct [
    :session_id,
    :export_id, 
    :export_spec,
    :progress,
    :stage
  ]
  
  # Progress reporting back to coordinator
  def report_progress(state, progress, stage) do
    GenServer.cast(
      get_session_pid(state.session_id),
      {:worker_progress, state.export_id, progress, stage}
    )
    
    broadcast_event(state.session_id, %ExportProgress{
      export_id: state.export_id,
      progress: progress,
      stage: stage
    })
  end
end
```

---

## 5. Agent Pool and Resource Management

### 5.1 Pool Implementation

```elixir
defmodule Arbor.AgentPool do
  use GenServer
  
  @default_max_concurrent 3
  @default_queue_timeout 30_000
  
  def init(opts) do
    max_concurrent = Keyword.get(opts, :max_concurrent, @default_max_concurrent)
    
    # ETS for real-time monitoring
    :ets.new(:agent_pool_workers, [
      :set, :public, :named_table,
      {:read_concurrency, true}
    ])
    
    {:ok, %{
      max_concurrent: max_concurrent,
      active_workers: %{},
      queue: :queue.new(),
      worker_count: 0
    }}
  end
  
  def handle_call({:request_worker, session_id, task_spec}, from, state) do
    if can_spawn_worker?(state) do
      spawn_and_track_worker(session_id, task_spec, from, state)
    else
      queue_work_request(session_id, task_spec, from, state)
    end
  end
  
  # Worker completion handling
  def handle_info({:DOWN, _ref, :process, worker_pid, _reason}, state) do
    state = remove_completed_worker(worker_pid, state)
    process_queued_work(state)
  end
  
  defp can_spawn_worker?(state) do
    state.worker_count < state.max_concurrent
  end
end
```

### 5.2 Rate Limiting and Backpressure

```elixir
defmodule Arbor.RateLimiter do
  use GenServer
  
  # Token bucket algorithm for rate limiting
  defstruct [
    :capacity,
    :tokens,
    :refill_rate,
    :last_refill
  ]
  
  def check_rate_limit(limiter_pid, cost \\ 1) do
    GenServer.call(limiter_pid, {:check_limit, cost})
  end
  
  def handle_call({:check_limit, cost}, _from, state) do
    state = refill_tokens(state)
    
    if state.tokens >= cost do
      {:reply, :ok, %{state | tokens: state.tokens - cost}}
    else
      {:reply, {:error, :rate_limited}, state}
    end
  end
end
```

---

## 6. Supervision Strategies

### 6.1 Fault Tolerance Patterns

```elixir
defmodule Arbor.Application do
  use Application
  
  def start(_type, _args) do
    children = [
      # Core infrastructure - restart always
      {Phoenix.PubSub, name: Arbor.PubSub},
      
      # Coordinator layer - restart on failure
      {Registry, keys: :unique, name: Arbor.SessionRegistry},
      {DynamicSupervisor, 
        name: Arbor.SessionSupervisor, 
        strategy: :one_for_one,
        max_restarts: 3,
        max_seconds: 5
      },
      Arbor.SessionManager,
      
      # Worker layer - selective restart
      supervisor(Arbor.AgentSupervisor, [], restart: :permanent),
      
      # Monitoring - always running
      Arbor.AgentMonitor,
      Arbor.Telemetry
    ]
    
    opts = [strategy: :one_for_one, name: Arbor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### 6.2 Recovery Strategies by Agent Type

| Component | Failure Impact | Recovery Strategy | Recovery Time |
|-----------|---------------|-------------------|---------------|
| Session Agent | Single session affected | Supervisor restart + state reload | <1s |
| SessionManager | Session discovery fails | Registry rebuild from ETS | <5s |
| Worker Agent | Single task fails | No restart, notify parent | 0s |
| AgentPool | Worker scheduling fails | Restart pool, requeue work | <2s |
| PubSub | Events lost temporarily | Auto-reconnect + state sync | <10s |

---

## 7. Communication Patterns

### 7.1 Event-Driven Architecture

```elixir
defmodule Arbor.Events do
  # Coordinator events
  defmodule SessionStarted do
    defstruct [:session_id, :user_id, :timestamp]
  end
  
  defmodule SessionStateChanged do
    defstruct [:session_id, :old_state, :new_state, :context]
  end
  
  # Worker events  
  defmodule WorkerSpawned do
    defstruct [:session_id, :worker_id, :worker_type, :task_spec]
  end
  
  defmodule WorkerProgress do
    defstruct [:session_id, :worker_id, :progress, :stage]
  end
  
  defmodule WorkerCompleted do
    defstruct [:session_id, :worker_id, :result, :duration_ms]
  end
  
  # Cross-agent communication
  defmodule AgentMessage do
    defstruct [:from_agent, :to_agent, :message_type, :payload]
  end
end
```

### 7.2 Pub/Sub Topics

```elixir
# Topic naming conventions
"session:#{session_id}"          # Session-specific events
"worker:#{worker_id}"           # Worker-specific events
"system:agents"                 # System-wide agent events
"system:maintenance"            # Maintenance notifications

# Subscription patterns
def subscribe_to_session(session_id) do
  Phoenix.PubSub.subscribe(Arbor.PubSub, "session:#{session_id}")
end

def subscribe_to_worker_events do
  Phoenix.PubSub.subscribe(Arbor.PubSub, "system:agents")
end
```

---

## 8. Agent Communication Examples

### 8.1 Coordinator-to-Worker Communication

```elixir
# In Session Agent (Coordinator)
def handle_cast({:analyze_codebase, repo_url}, state) do
  task_spec = %{
    tool_name: "analyze_codebase",
    args: %{"repo_url" => repo_url},
    timeout: 300_000  # 5 minutes
  }
  
  case Arbor.SessionManager.spawn_subagent(state.session_id, :tool_executor, task_spec) do
    {:ok, worker_id, worker_pid} ->
      new_state = track_active_worker(state, worker_id, worker_pid)
      {:noreply, new_state}
      
    error ->
      broadcast_error(state.session_id, error)
      {:noreply, state}
  end
end

# Handle worker completion
def handle_info({:worker_completed, worker_id, result}, state) do
  state = remove_active_worker(state, worker_id)
  state = process_worker_result(state, result)
  {:noreply, state}
end
```

### 8.2 Worker-to-Coordinator Communication

```elixir
# In Tool Executor Agent (Worker)
def execute_with_progress(task_spec, session_id) do
  # Report initial status
  notify_coordinator(session_id, {:worker_started, self()})
  
  # Execute with progress updates
  result = task_spec.tool_name
  |> get_tool_module()
  |> apply(:execute, [task_spec.args, &progress_callback/2])
  
  # Report completion
  notify_coordinator(session_id, {:worker_completed, self(), result})
  
  result
end

defp progress_callback(progress, stage) do
  GenServer.cast(self(), {:update_progress, progress, stage})
end

defp notify_coordinator(session_id, message) do
  case Arbor.SessionManager.get_session_pid(session_id) do
    {:ok, pid} -> send(pid, message)
    _ -> :ok
  end
end
```

---

## 9. Specialized Agent Implementations

### 9.1 Maintenance Agent (Singleton Worker)

```elixir
defmodule Arbor.MaintenanceAgent do
  use GenServer
  
  @cleanup_interval :timer.hours(1)
  @deep_clean_hour 2  # 2 AM
  
  def init(_opts) do
    schedule_next_maintenance()
    
    {:ok, %{
      last_cleanup: nil,
      cleanup_count: 0,
      stats: %{
        sessions_cleaned: 0,
        logs_rotated: 0,
        temp_files_deleted: 0
      }
    }}
  end
  
  def handle_info(:maintenance, state) do
    current_hour = DateTime.utc_now().hour
    is_deep_clean = current_hour == @deep_clean_hour
    
    stats = perform_maintenance(is_deep_clean)
    new_state = update_stats(state, stats)
    
    schedule_next_maintenance()
    broadcast_maintenance_complete(stats)
    
    {:noreply, new_state}
  end
  
  defp perform_maintenance(deep_clean?) do
    tasks = [
      &cleanup_inactive_sessions/0,
      &cleanup_temp_files/0
    ]
    
    tasks = if deep_clean? do
      tasks ++ [&rotate_logs/0, &cleanup_old_exports/0]
    else
      tasks
    end
    
    execute_maintenance_tasks(tasks)
  end
end
```

### 9.2 Export Agent (Dynamic Worker)

```elixir
defmodule Arbor.ExportAgent do
  use GenServer, restart: :temporary
  
  def handle_info(:start_export, state) do
    try do
      broadcast_started(state)
      
      export_result = generate_export(
        state.session_id,
        state.export_spec,
        progress_callback: &report_progress/3
      )
      
      storage_result = store_export(state.export_id, export_result)
      
      broadcast_completed(state, storage_result)
      {:stop, :normal, state}
      
    rescue
      error ->
        broadcast_failed(state, error)
        {:stop, :normal, state}
    end
  end
  
  defp generate_export(session_id, %{format: "pdf"} = spec, opts) do
    callback = Keyword.get(opts, :progress_callback)
    
    callback.(self(), session_id, 10)
    session_data = fetch_session_data(session_id)
    
    callback.(self(), session_id, 50)
    pdf_content = render_pdf(session_data, spec)
    
    callback.(self(), session_id, 100)
    
    %{
      content: pdf_content,
      content_type: "application/pdf",
      size: byte_size(pdf_content)
    }
  end
end
```

---

## 10. Performance Considerations

### 10.1 Memory Management

**Per-Agent Memory Footprint:**
- **Session Agent**: ~50-100KB active, ~10KB hibernated
- **Worker Agent**: ~5-20KB depending on task
- **Base GenServer**: ~2KB process overhead

**Scaling Estimates:**
- 1,000 concurrent sessions: ~100MB
- 10,000 concurrent sessions: ~1GB
- 100 concurrent workers: ~2MB

**Optimization Strategies:**
```elixir
# Hibernate idle sessions
def handle_info(:check_idle, state) do
  if idle_too_long?(state) do
    {:noreply, state, :hibernate}
  else
    schedule_idle_check()
    {:noreply, state}
  end
end

# Stream large datasets
def handle_large_export(session_id, spec) do
  Stream.resource(
    fn -> init_export(session_id) end,
    fn state -> fetch_next_batch(state) end,
    fn state -> cleanup_export(state) end
  )
  |> Stream.each(&write_to_file/1)
  |> Stream.run()
end
```

### 10.2 Concurrency Patterns

```elixir
# Parallel worker execution
def execute_parallel_analysis(repo_urls) do
  repo_urls
  |> Enum.map(&spawn_analysis_worker/1)
  |> Enum.map(&await_worker_result/1)
  |> aggregate_results()
end

# Flow-based processing for large datasets
def process_large_dataset(dataset_path) do
  Flow.from_enumerable(File.stream!(dataset_path))
  |> Flow.partition()
  |> Flow.map(&process_record/1)
  |> Flow.reduce(fn -> %{} end, &aggregate_record/2)
  |> Enum.to_list()
end
```

---

## 11. Monitoring and Observability

### 11.1 Agent Monitor Implementation

```elixir
defmodule Arbor.AgentMonitor do
  use GenServer
  
  def init(_opts) do
    schedule_health_check()
    
    {:ok, %{
      checks: configure_health_checks(),
      status: %{},
      alerts: []
    }}
  end
  
  def handle_info(:health_check, state) do
    results = run_health_checks(state.checks)
    new_state = process_health_results(state, results)
    
    schedule_health_check()
    {:noreply, new_state}
  end
  
  defp configure_health_checks do
    [
      {:session_count, &check_session_count/0, max: 1000},
      {:worker_pool, &check_worker_pool_health/0, max_queued: 50},
      {:memory_usage, &check_memory_usage/0, max_mb: 500},
      {:message_queue, &check_message_queues/0, max_length: 100}
    ]
  end
end
```

### 11.2 Telemetry Integration

```elixir
# Emit telemetry events
:telemetry.execute(
  [:arbor, :agent, :spawned],
  %{count: 1},
  %{agent_type: :tool_executor, session_id: session_id}
)

# Attach handlers
:telemetry.attach(
  "arbor-agent-metrics",
  [:arbor, :agent, :spawned],
  &handle_agent_spawned/4,
  nil
)
```

---

## 12. Best Practices

### 12.1 Agent Design Principles

1. **Single Responsibility**: Each agent type should have one clear purpose
2. **Fail Fast**: Workers should crash on errors, coordinators should handle failures
3. **Message Passing**: Prefer async messages over synchronous calls when possible
4. **State Isolation**: Never share state directly between agents
5. **Supervision**: Choose appropriate restart strategies per agent type

### 12.2 Communication Guidelines

```elixir
# Good: Async notification
send(coordinator_pid, {:worker_progress, self(), 50})

# Good: Fire-and-forget broadcast
Phoenix.PubSub.broadcast(pubsub, topic, event)

# Avoid: Synchronous calls in tight loops
Enum.each(workers, fn w -> 
  GenServer.call(w, :get_status)  # Will block!
end)

# Better: Gather async
workers
|> Enum.map(&send(&1, {:get_status, self()}))
|> Enum.map(fn _ -> receive do {:status, s} -> s end end)
```

### 12.3 Testing Strategies

```elixir
# Test coordinator-worker interaction
test "session spawns worker for heavy task" do
  {:ok, session_pid} = start_supervised({Arbor.Session, session_id: "test"})
  
  # Request heavy task
  GenServer.cast(session_pid, {:analyze_codebase, "http://example.com/repo"})
  
  # Verify worker spawned
  assert_receive {:worker_spawned, worker_id, :tool_executor}, 1000
  
  # Verify completion
  assert_receive {:worker_completed, ^worker_id, _result}, 5000
end
```

---

## Conclusion

This two-tiered agent architecture provides a robust foundation for Arbor's concurrent operations. By separating coordinator agents (long-lived, stateful) from worker agents (task-specific, temporary), the system achieves:

- **Scalability**: Independent scaling of session management and task execution
- **Fault Tolerance**: Isolated failures with appropriate recovery strategies
- **Resource Management**: Controlled concurrency through agent pools
- **Observability**: Built-in monitoring and event-driven updates
- **Clean Architecture**: Clear separation of concerns and responsibilities

The pure OTP implementation ensures the system remains maintainable, testable, and aligned with Elixir/Erlang best practices, while the event-driven communication enables real-time UI updates and system monitoring.