# Agent Command Architecture

This document consolidates the command architecture for the enhanced agent system, covering the asynchronous command/event pattern, execution flow, progress tracking, error handling, and real-world implementations.

## Architecture Overview

The agent command architecture provides a sophisticated hybrid approach that integrates CLI commands with specialized AI agents:

1. **Asynchronous Command/Event Pattern** - Commands are executed asynchronously with real-time progress updates via Phoenix.PubSub
2. **Three-Tier Command Model** - Commands are classified into Client-Bound, Client-Orchestrated, and Agent-Exclusive categories
3. **Dynamic Discovery** - Commands are discovered from connected agents at runtime rather than hardcoded
4. **Fault Isolation** - Each agent runs in its own GenServer process with temporary restart strategy

## Core Architectural Principles

### Asynchronous Execution Model

The system uses a lightweight GenServer-per-task approach:

```elixir
# Task execution with isolated state
defmodule Arbor.Agents.TaskExecutor do
  use GenServer, restart: :temporary
  
  def start_link(task_spec) do
    GenServer.start_link(__MODULE__, task_spec)
  end
  
  @impl true
  def init(task_spec) do
    # Execute task asynchronously
    send(self(), :execute)
    {:ok, %{task: task_spec, start_time: System.monotonic_time()}}
  end
  
  @impl true
  def handle_info(:execute, state) do
    # Publish progress updates
    publish_progress(state.task.session_id, 0, "Starting execution")
    
    # Execute with progress tracking
    result = execute_with_progress(state.task)
    
    # Publish completion
    publish_completion(state.task.session_id, result)
    
    {:stop, :normal, state}
  end
end
```

### Event Publication Pattern

All agents communicate progress and results through standardized PubSub events:

```elixir
defmodule Arbor.Events do
  @moduledoc "Standardized event structures for agent communication"
  
  def task_started(session_id, task_id, agent_name, estimated_duration) do
    %{
      event: :task_started,
      session_id: session_id,
      task_id: task_id,
      agent: agent_name,
      estimated_duration: estimated_duration,
      timestamp: DateTime.utc_now()
    }
  end
  
  def task_progress(session_id, task_id, progress, message) do
    %{
      event: :task_progress,
      session_id: session_id,
      task_id: task_id,
      progress: progress, # 0-100
      message: message,
      timestamp: DateTime.utc_now()
    }
  end
  
  def task_completed(session_id, task_id, result) do
    %{
      event: :task_completed,
      session_id: session_id,
      task_id: task_id,
      result: result,
      timestamp: DateTime.utc_now()
    }
  end
  
  def task_failed(session_id, task_id, error) do
    %{
      event: :task_failed,
      session_id: session_id,
      task_id: task_id,
      error: error,
      timestamp: DateTime.utc_now()
    }
  end
end
```

## Command Classification System

### 1. Client-Bound Commands
Pure local operations with no agent involvement:

```bash
# UI/System Management
/help                    # Show available commands
/clear                   # Clear screen
/tui                     # Switch to TUI mode
/alias                   # Manage command aliases
/exit, /quit            # Exit application

# Local Session Management
/sessions                # List saved sessions
/history                 # Show command history
```

### 2. Client-Orchestrated Commands
Client owns state but delegates validation/analysis to agents:

```bash
# Model/Backend Management
/model switch <name>     # Client updates after agent validation
/backend <name>          # Client switches after compatibility check

# Context Management
/context add <file>      # Client manages files, agent validates
/system <prompt>         # Client sets after agent analysis
/tokens <number>         # Client updates after validation
/strategy <type>         # Client sets after agent review
```

#### Orchestration Flow Example

```elixir
defmodule Arbor.Commands.ModelSwitch do
  def handle(session, model_name) do
    # 1. Create validation task
    task_spec = %{
      command: "model_validate",
      args: [model_name],
      context: %{
        current_backend: session.backend,
        current_model: session.model,
        capabilities_required: extract_capabilities(session)
      },
      session_id: session.id
    }
    
    # 2. Dispatch to agent
    {:ok, task_id} = AgentPool.execute_task(:llm_agent, task_spec)
    
    # 3. Wait for validation result
    receive do
      {:task_completed, ^task_id, %{valid: true, warnings: warnings}} ->
        # Update client state
        updated_session = Session.update_model(session, model_name)
        {:ok, updated_session, warnings}
        
      {:task_completed, ^task_id, %{valid: false, reason: reason}} ->
        {:error, reason}
        
      {:task_failed, ^task_id, error} ->
        {:error, "Validation failed: #{error}"}
    after
      30_000 -> {:error, :timeout}
    end
  end
end
```

### 3. Agent-Exclusive Commands
Pure agent operations with no client state changes:

```bash
# LLM Analysis
/model recommend [features]      # AI-powered recommendations
/model compare <models>          # Multi-dimensional comparison
/model capabilities [model]      # Capability analysis
/acceleration analyze            # Hardware optimization

# MCP Operations
/mcp discover                    # Server discovery
/mcp tools                       # Tool capability listing
/mcp resources                   # Resource discovery
/mcp sample <server> <prompt>    # Server-side AI generation

# Analysis & Export
/cost [detailed]                 # Cost analysis
/stats [--insights]              # Session analytics
/export [format]                 # Smart export formatting
```

## Agent Behavior Contract

All agents must implement standardized interfaces:

```elixir
defmodule Arbor.Agents.Agent do
  @doc "Returns available commands with metadata"
  @callback available_commands() :: %{String.t() => command_spec()}
  
  @doc "Validates required context is present"
  @callback validate_context(context :: map()) :: :ok | {:error, reason :: String.t()}
  
  @doc "Returns required context keys for operation"
  @callback get_required_context_keys() :: [atom()]
  
  @doc "Executes task and returns result"
  @callback handle_task(task_spec :: map()) :: {:ok, result :: map()} | {:error, reason :: any()}
  
  @type command_spec :: %{
    description: String.t(),
    args: [arg_spec()],
    examples: [String.t()],
    category: atom()
  }
  
  @type arg_spec :: %{
    name: String.t(),
    type: :string | :number | :boolean | :list,
    required: boolean(),
    description: String.t()
  }
end
```

## Command Execution Flow

### 1. Command Reception
```elixir
# User input: /model recommend vision streaming

# CLI parses and routes
{:agent_command, :llm_agent, "model", ["recommend", "vision", "streaming"]}
```

### 2. Task Specification Creation
```elixir
task_spec = %{
  command: "model_recommend",
  args: ["vision", "streaming"],
  context: %{
    current_backend: "anthropic",
    current_model: "claude-3-sonnet",
    budget_constraints: nil,
    usage_patterns: session.usage_stats
  },
  session_id: session.id,
  timeout: 30_000
}
```

### 3. Agent Dispatch
```elixir
defmodule Arbor.AgentPool do
  def execute_task(agent_type, task_spec) do
    # Generate unique task ID
    task_id = generate_task_id()
    
    # Start supervised task
    {:ok, pid} = TaskSupervisor.start_child(
      Arbor.TaskSupervisor,
      fn -> 
        agent_module = get_agent_module(agent_type)
        agent_module.execute(task_spec)
      end
    )
    
    # Track active task
    :ets.insert(:active_tasks, {task_id, pid, agent_type})
    
    {:ok, task_id}
  end
end
```

### 4. Progress Tracking
```elixir
defmodule Arbor.Agents.LLMAgent do
  def execute(task_spec) do
    # Publish start event
    publish_event(:task_started, task_spec.session_id, 
                  agent: "llm_agent", 
                  estimated_duration: estimate_duration(task_spec))
    
    # Execute with progress updates
    task_spec
    |> validate_context()
    |> analyze_requirements(fn progress -> 
      publish_event(:task_progress, task_spec.session_id,
                    progress: progress,
                    message: "Analyzing model capabilities")
    end)
    |> generate_recommendations()
    |> format_results()
  end
end
```

### 5. Result Delivery
```elixir
# Success case
publish_event(:task_completed, session_id, %{
  recommendations: [
    %{model: "gpt-4-vision-preview", score: 0.95, reasons: [...]},
    %{model: "claude-3-opus", score: 0.88, reasons: [...]}
  ],
  analysis: %{
    feature_coverage: %{vision: true, streaming: true},
    cost_comparison: %{...},
    performance_metrics: %{...}
  }
})

# Error case
publish_event(:task_failed, session_id, %{
  error: :invalid_features,
  message: "Feature 'streaming' not available in any vision model",
  suggestions: ["Try 'function_calling' instead"]
})
```

## Progress Tracking and Notifications

### Real-time Progress Display
```
🤖 Executing with llm_agent...
🚀 Started: model_recommendation
⏱ Estimated duration: 8s
🔄 [██████████░░░░░░░░░░] 50% - Analyzing capabilities
🔄 [████████████████░░░░] 85% - Comparing models
🔄 [████████████████████] 100% - Formatting results
✅ Completed: model_recommendation
```

### Progress Event Structure
```elixir
%{
  event: :task_progress,
  session_id: "session_123",
  task_id: "task_456",
  progress: 50,  # 0-100
  message: "Analyzing capabilities",
  metadata: %{
    models_analyzed: 15,
    models_remaining: 15,
    current_phase: :capability_analysis
  }
}
```

## Error Handling Strategies

### 1. Validation Errors
Caught before task execution:

```elixir
def validate_task(task_spec) do
  with :ok <- validate_required_fields(task_spec),
       :ok <- validate_context(task_spec.context),
       :ok <- validate_args(task_spec.args) do
    {:ok, task_spec}
  else
    {:error, reason} ->
      publish_event(:task_failed, task_spec.session_id, %{
        error: :validation_failed,
        reason: reason,
        phase: :pre_execution
      })
      {:error, reason}
  end
end
```

### 2. Execution Errors
Handled during task processing:

```elixir
def execute_with_recovery(task_spec) do
  try do
    execute_task(task_spec)
  rescue
    e in RuntimeError ->
      handle_runtime_error(e, task_spec)
    e in TimeoutError ->
      handle_timeout(e, task_spec)
  catch
    :exit, reason ->
      handle_exit(reason, task_spec)
  end
end
```

### 3. Resource Errors
Managed through supervision:

```elixir
defmodule Arbor.TaskSupervisor do
  use Supervisor
  
  def init(_) do
    children = [
      {Task.Supervisor, 
       name: Arbor.TaskExecutor,
       restart: :transient,
       max_restarts: 3,
       max_seconds: 5}
    ]
    
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

### 4. Smart Error Suggestions
```elixir
def generate_error_suggestions(error) do
  case error do
    {:unknown_command, input} ->
      %{
        suggestions: find_similar_commands(input),
        message: "Did you mean one of these?"
      }
      
    {:model_not_available, model} ->
      %{
        suggestions: find_alternative_models(model),
        message: "This model is not available. Try these alternatives:"
      }
      
    {:invalid_context, missing_keys} ->
      %{
        suggestions: ["Add required context: #{inspect(missing_keys)}"],
        message: "Missing required context for this operation"
      }
  end
end
```

## Real-World Examples

### Model Management Workflow
```bash
# User wants to find best model for their use case
/model recommend vision function_calling
# Agent analyzes requirements and returns recommendations

# User compares top recommendations
/model compare gpt-4-vision-preview claude-3-opus
# Agent provides detailed comparison matrix

# User switches model with validation
/model switch claude-3-opus
# Agent validates compatibility, client updates if valid

# User verifies new capabilities
/model capabilities
# Agent analyzes current model capabilities
```

### MCP Server Integration
```bash
# Discover available MCP servers
/mcp discover
# Agent scans and reports available servers

# Connect with auto-configuration
/mcp connect filesystem
# Agent validates and establishes connection

# Execute tool with progress monitoring
/mcp tool filesystem analyze_directory ~/code/myproject
# Agent executes with real-time progress updates
```

### Cost Optimization Flow
```bash
# Analyze current session costs
/cost detailed
# Agent provides breakdown and insights

# Get optimization recommendations
/stats --cost-analysis
# Agent analyzes usage patterns and suggests optimizations

# Find budget-friendly alternatives
/model recommend --budget 0.10 --task "document analysis"
# Agent finds models within budget constraints
```

## Configuration

### Environment Variables
```bash
# Enable/disable enhanced commands
export MCP_ENHANCED_COMMANDS=true   # Force enable
export MCP_ENHANCED_COMMANDS=false  # Force disable

# Debug mode for command routing
export MCP_DEBUG=1

# Agent execution timeouts
export AGENT_TASK_TIMEOUT=120000    # 2 minutes default
export AGENT_QUEUE_TIMEOUT=30000    # 30 seconds queue wait
```

### Agent Pool Configuration
```elixir
config :mcp_chat, :agent_pool,
  max_concurrent: 5,           # Maximum concurrent agent tasks
  queue_timeout: 30_000,       # Max time in queue
  default_timeout: 120_000,    # Default task execution timeout
  progress_interval: 1_000     # Progress update frequency
```

## Implementation Guidelines

### Agent Autonomy Rules

**Agents SHOULD:**
- Validate their context and requirements
- Perform analysis and return recommendations
- Manage their own specialized state (caches, etc.)
- Provide rich metadata about capabilities
- Report progress for long-running operations

**Agents SHOULD NOT:**
- Directly modify client session state
- Make autonomous changes without approval
- Access data they weren't explicitly given
- Assume persistent state between invocations
- Perform actions affecting other agents

### State Management Pattern
```elixir
# Bad: Agent directly modifies session
def handle_task(%{command: "switch_model", args: [model]}) do
  Session.update_session(session_id, model: model)  # ❌ Tight coupling
end

# Good: Agent returns recommendation, client decides
def handle_task(%{command: "switch_model", args: [model]}) do
  validation = validate_model_compatibility(model, context)
  {:ok, %{valid: validation.valid, warnings: validation.warnings}}  # ✅ Loose coupling
end
```

## Migration Strategy

### Phase 1: Foundation
1. Create Agent behavior contract
2. Implement base agent capabilities  
3. Refactor command routing for dynamic discovery

### Phase 2: Standardization
1. Update all agents to new contract
2. Implement three-tier command classification
3. Add comprehensive progress tracking

### Phase 3: Enhancement
1. Add command caching strategies
2. Implement usage analytics
3. Create interactive documentation system

### Backward Compatibility
- All existing commands continue working
- Legacy handlers remain functional
- Enhanced features activate automatically
- No breaking changes to workflows

## Summary

The agent command architecture provides a robust foundation for AI-powered CLI operations through:

- **Asynchronous execution** with real-time progress tracking
- **Clear command classification** into three architectural tiers  
- **Standardized agent contracts** ensuring consistency
- **Fault-tolerant design** leveraging OTP principles
- **Flexible error handling** with smart recovery strategies

This architecture balances simplicity with power, providing excellent fault isolation while maintaining responsive user experiences through the event-driven progress system.