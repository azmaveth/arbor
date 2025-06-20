# Integration Patterns

This document describes the integration patterns for connecting different client types (CLI, Web, API) with Arbor's distributed agent architecture, incorporating security through capability-based access control.

## Table of Contents

1. [Overview](#overview)
2. [Gateway Pattern](#gateway-pattern)
3. [Client Integration Patterns](#client-integration-patterns)
4. [Security Integration](#security-integration)
5. [Event-Driven Architecture](#event-driven-architecture)
6. [Multi-Client Support](#multi-client-support)
7. [Implementation Guidelines](#implementation-guidelines)

## Overview

Arbor's integration architecture enables multiple client types to interact with the distributed agent system while maintaining security, real-time updates, and consistent behavior across all interfaces.

### Key Integration Components

```
┌─────────────────────────────────────────────────────────────────┐
│                        Client Layer                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐   │
│  │  CLI Client │  │ Web Client  │  │    API Client       │   │
│  └─────────────┘  └─────────────┘  └─────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
           │                │                    │
           ▼                ▼                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Gateway Pattern                              │
│  ┌─────────────────┐              ┌─────────────────────────┐  │
│  │  Unified API    │              │  Session Management     │  │
│  │  Gateway        │              │  & Security             │  │
│  └─────────────────┘              └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
           │                                    │
           ▼                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                 Distributed Agent Layer                         │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐│
│  │  Agent Pool     │  │ Security Kernel │  │  Event Bus      ││
│  │  & Scheduling   │  │ & Capabilities  │  │  (PubSub)       ││
│  └─────────────────┘  └─────────────────┘  └─────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

## Gateway Pattern

The Gateway pattern provides a unified interface for all client types, abstracting the complexity of the distributed agent system.

### Gateway API Implementation

```elixir
defmodule Arbor.Gateway do
  @moduledoc """
  Unified gateway for client interactions with the agent system.
  """
  
  alias Arbor.Security
  alias Arbor.AgentPool
  alias Arbor.Sessions
  
  @doc """
  Create a new session with security context.
  """
  def create_session(client_type, auth_token, opts \\ []) do
    with {:ok, principal} <- authenticate_client(auth_token),
         {:ok, capabilities} <- request_capabilities(principal, client_type),
         {:ok, session} <- Sessions.create(principal, capabilities, opts) do
      
      # Subscribe client to session events
      Phoenix.PubSub.subscribe(Arbor.PubSub, "session:#{session.id}")
      
      {:ok, %{
        session_id: session.id,
        capabilities: capabilities,
        event_channel: "session:#{session.id}"
      }}
    end
  end
  
  @doc """
  Execute a command through the gateway.
  """
  def execute_command(session_id, command, args, opts \\ []) do
    with {:ok, session} <- Sessions.get(session_id),
         :ok <- validate_command_permission(session, command),
         {:ok, task_spec} <- build_task_spec(command, args, session) do
      
      case determine_execution_mode(task_spec) do
        :sync ->
          execute_sync(task_spec, opts)
          
        :async ->
          execute_async(task_spec, opts)
      end
    end
  end
  
  @doc """
  Request an export with progress tracking.
  """
  def request_export(session_id, format, options) do
    with {:ok, session} <- Sessions.get(session_id),
         :ok <- validate_export_permission(session, format),
         {:ok, export_id} <- generate_export_id() do
      
      # Queue export task
      task_spec = %{
        type: :export,
        format: format,
        options: options,
        session_id: session_id,
        export_id: export_id
      }
      
      AgentPool.queue_task(task_spec)
      
      {:ok, %{export_id: export_id}}
    end
  end
  
  defp execute_async(task_spec, opts) do
    execution_id = generate_execution_id()
    
    # Broadcast start event
    broadcast_event(task_spec.session_id, %{
      type: :execution_started,
      execution_id: execution_id,
      task: sanitize_task_spec(task_spec)
    })
    
    # Queue for async execution
    AgentPool.queue_task(Map.put(task_spec, :execution_id, execution_id))
    
    {:ok, :async, %{execution_id: execution_id}}
  end
end
```

### Gateway Session Management

```elixir
defmodule Arbor.Gateway.SessionManager do
  @moduledoc """
  Manages client sessions across different interfaces.
  """
  
  use GenServer
  alias Arbor.Security
  
  defstruct [:sessions, :client_registry]
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(_opts) do
    {:ok, %__MODULE__{
      sessions: %{},
      client_registry: %{}
    }}
  end
  
  @doc """
  Register a client connection with a session.
  """
  def register_client(session_id, client_info) do
    GenServer.call(__MODULE__, {:register_client, session_id, client_info})
  end
  
  @doc """
  Get all active clients for a session.
  """
  def get_session_clients(session_id) do
    GenServer.call(__MODULE__, {:get_clients, session_id})
  end
  
  def handle_call({:register_client, session_id, client_info}, _from, state) do
    client_id = generate_client_id()
    
    updated_registry = Map.update(
      state.client_registry,
      session_id,
      [client_info],
      &[client_info | &1]
    )
    
    # Set up client monitoring
    if client_info[:pid] do
      Process.monitor(client_info.pid)
    end
    
    {:reply, {:ok, client_id}, %{state | client_registry: updated_registry}}
  end
end
```

## Client Integration Patterns

### CLI Integration

The CLI integration uses an event-driven bridge pattern for real-time updates:

```elixir
defmodule Arbor.CLI.Integration do
  @moduledoc """
  CLI integration with the gateway pattern.
  """
  
  alias Arbor.Gateway
  alias Arbor.CLI.EventSubscriber
  alias Arbor.CLI.ProgressRenderer
  
  defstruct [:session_id, :capabilities, :event_subscriber]
  
  @doc """
  Initialize CLI session with gateway.
  """
  def init_session(auth_token \\ nil) do
    # Use system credentials if no token provided
    auth = auth_token || get_system_auth()
    
    with {:ok, session_data} <- Gateway.create_session(:cli, auth),
         {:ok, subscriber} <- EventSubscriber.start_link(session_data.session_id) do
      
      %__MODULE__{
        session_id: session_data.session_id,
        capabilities: session_data.capabilities,
        event_subscriber: subscriber
      }
    end
  end
  
  @doc """
  Execute command with progress tracking.
  """
  def execute_command(session, command, args) do
    case Gateway.execute_command(session.session_id, command, args) do
      {:ok, :async, %{execution_id: id}} ->
        # Progress will be shown via event subscriber
        wait_for_completion(id)
        
      {:ok, result} ->
        # Immediate result
        {:ok, result}
        
      {:error, reason} = error ->
        ProgressRenderer.render_error("Command failed: #{inspect(reason)}")
        error
    end
  end
  
  defp wait_for_completion(execution_id) do
    receive do
      {:execution_completed, ^execution_id, result} ->
        {:ok, result}
        
      {:execution_failed, ^execution_id, reason} ->
        {:error, reason}
    after
      :timer.minutes(30) ->
        {:error, :timeout}
    end
  end
end
```

### Web Client Integration

Web clients use WebSocket connections for real-time updates:

```elixir
defmodule ArborWeb.ClientSocket do
  @moduledoc """
  WebSocket integration for web clients.
  """
  
  use Phoenix.Socket
  alias Arbor.Gateway
  
  channel "session:*", ArborWeb.SessionChannel
  
  def connect(%{"token" => token}, socket, _connect_info) do
    case Gateway.authenticate_token(token) do
      {:ok, principal} ->
        {:ok, assign(socket, :principal, principal)}
        
      {:error, _reason} ->
        :error
    end
  end
  
  def id(socket), do: "client:#{socket.assigns.principal.id}"
end

defmodule ArborWeb.SessionChannel do
  @moduledoc """
  Phoenix channel for session communication.
  """
  
  use Phoenix.Channel
  alias Arbor.Gateway
  
  def join("session:" <> session_id, _params, socket) do
    if authorized?(socket, session_id) do
      # Register web client
      Gateway.SessionManager.register_client(session_id, %{
        type: :web,
        pid: self(),
        socket_id: socket.id
      })
      
      # Subscribe to session events
      Phoenix.PubSub.subscribe(Arbor.PubSub, "session:#{session_id}")
      
      {:ok, assign(socket, :session_id, session_id)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end
  
  def handle_in("execute_command", %{"command" => cmd, "args" => args}, socket) do
    case Gateway.execute_command(socket.assigns.session_id, cmd, args) do
      {:ok, :async, %{execution_id: id}} ->
        {:reply, {:ok, %{execution_id: id, mode: "async"}}, socket}
        
      {:ok, result} ->
        {:reply, {:ok, %{result: result, mode: "sync"}}, socket}
        
      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end
  
  # Forward PubSub events to WebSocket
  def handle_info({:execution_progress, progress}, socket) do
    push(socket, "execution_progress", progress)
    {:noreply, socket}
  end
end
```

### API Client Integration

RESTful API with webhook support for async operations:

```elixir
defmodule ArborWeb.APIController do
  @moduledoc """
  REST API integration for programmatic clients.
  """
  
  use ArborWeb, :controller
  alias Arbor.Gateway
  
  def create_session(conn, %{"client_type" => type} = params) do
    auth_token = get_auth_token(conn)
    
    case Gateway.create_session(type, auth_token, params) do
      {:ok, session_data} ->
        json(conn, %{
          session_id: session_data.session_id,
          capabilities: render_capabilities(session_data.capabilities),
          webhook_url: build_webhook_url(session_data.session_id)
        })
        
      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: reason})
    end
  end
  
  def execute_command(conn, %{"session_id" => session_id} = params) do
    command = params["command"]
    args = params["args"] || %{}
    webhook_url = params["webhook_url"]
    
    case Gateway.execute_command(session_id, command, args) do
      {:ok, :async, %{execution_id: id}} ->
        # Register webhook if provided
        if webhook_url do
          register_webhook(session_id, id, webhook_url)
        end
        
        conn
        |> put_status(:accepted)
        |> json(%{
          execution_id: id,
          status: "pending",
          poll_url: Routes.api_path(conn, :get_execution, id)
        })
        
      {:ok, result} ->
        json(conn, %{status: "completed", result: result})
        
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end
end
```

## Security Integration

### Capability-Based Access Control

All client operations are validated against capabilities:

```elixir
defmodule Arbor.Integration.Security do
  @moduledoc """
  Security integration for client operations.
  """
  
  alias Arbor.Security
  alias Arbor.Security.Capability
  
  @doc """
  Request capabilities based on client type.
  """
  def request_client_capabilities(principal_id, client_type) do
    base_capabilities = get_base_capabilities(client_type)
    
    Enum.reduce_while(base_capabilities, {:ok, []}, fn cap_spec, {:ok, caps} ->
      case Security.request_capability(
        cap_spec.resource_type,
        cap_spec.constraints,
        principal_id
      ) do
        {:ok, cap} -> {:cont, {:ok, [cap | caps]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
  
  defp get_base_capabilities(:cli) do
    [
      %{
        resource_type: :cli_operations,
        constraints: %{
          operations: [:read, :write, :execute],
          rate_limit: 1000
        }
      },
      %{
        resource_type: :mcp_tool,
        constraints: %{
          operations: [:execute, :list],
          rate_limit: 100
        }
      }
    ]
  end
  
  defp get_base_capabilities(:web) do
    [
      %{
        resource_type: :web_operations,
        constraints: %{
          operations: [:read, :write],
          rate_limit: 500,
          max_concurrent: 10
        }
      }
    ]
  end
  
  defp get_base_capabilities(:api) do
    [
      %{
        resource_type: :api_operations,
        constraints: %{
          operations: [:read, :write, :execute],
          rate_limit: 10000,
          require_webhook: true
        }
      }
    ]
  end
end
```

### Secure Command Routing

Commands are routed through security validation:

```elixir
defmodule Arbor.Integration.SecureRouter do
  @moduledoc """
  Secure routing for client commands.
  """
  
  alias Arbor.Security
  alias Arbor.AgentPool
  
  # Command risk levels
  @command_policies %{
    "export" => %{risk_level: :high, requires_audit: true},
    "mcp" => %{risk_level: :medium, rate_limited: true},
    "chat" => %{risk_level: :low},
    "help" => %{risk_level: :minimal}
  }
  
  def route_command(session, command, args) do
    with :ok <- validate_command_permission(session, command),
         :ok <- check_rate_limits(session, command),
         {:ok, task_spec} <- build_secure_task_spec(session, command, args) do
      
      # Audit high-risk commands
      if requires_audit?(command) do
        audit_command_execution(session, command, args)
      end
      
      # Route to appropriate agent
      route_to_agent(task_spec)
    end
  end
  
  defp validate_command_permission(session, command) do
    policy = Map.get(@command_policies, command, %{risk_level: :medium})
    
    # Find appropriate capability
    capability = find_capability_for_command(session.capabilities, command)
    
    if capability do
      Security.validate_capability(capability, :execute, command)
    else
      {:error, :no_capability}
    end
  end
  
  defp check_rate_limits(session, command) do
    if rate_limited?(command) do
      key = "#{session.principal_id}:#{command}"
      limit = get_command_rate_limit(command)
      
      case Hammer.check_rate(key, :timer.minutes(60), limit) do
        {:allow, _count} -> :ok
        {:deny, _limit} -> {:error, :rate_limit_exceeded}
      end
    else
      :ok
    end
  end
  
  defp build_secure_task_spec(session, command, args) do
    {:ok, %{
      command: command,
      args: args,
      session_id: session.id,
      principal_id: session.principal_id,
      capabilities: filter_relevant_capabilities(session.capabilities, command),
      security_context: %{
        risk_level: get_risk_level(command),
        audit_required: requires_audit?(command),
        constraints: get_command_constraints(command)
      }
    }}
  end
end
```

## Event-Driven Architecture

### Real-time Event Distribution

Events are distributed to all connected clients:

```elixir
defmodule Arbor.Integration.EventBroadcaster do
  @moduledoc """
  Broadcasts events to all registered clients for a session.
  """
  
  alias Arbor.Gateway.SessionManager
  
  def broadcast_to_session(session_id, event) do
    # Get all clients for this session
    clients = SessionManager.get_session_clients(session_id)
    
    # Broadcast via PubSub for subscribed clients
    Phoenix.PubSub.broadcast(
      Arbor.PubSub,
      "session:#{session_id}",
      format_event(event)
    )
    
    # Send webhooks for API clients
    send_webhooks(clients, session_id, event)
    
    # Update any persistent stores
    update_event_log(session_id, event)
  end
  
  defp format_event(event) do
    %{
      type: event.type,
      timestamp: DateTime.utc_now(),
      data: event.data,
      metadata: %{
        source: event[:source] || "system",
        severity: event[:severity] || "info"
      }
    }
  end
  
  defp send_webhooks(clients, session_id, event) do
    api_clients = Enum.filter(clients, &(&1.type == :api))
    
    Enum.each(api_clients, fn client ->
      if webhook_url = client[:webhook_url] do
        send_webhook_async(webhook_url, session_id, event)
      end
    end)
  end
end
```

### Progress Tracking

Unified progress tracking across all client types:

```elixir
defmodule Arbor.Integration.ProgressTracker do
  @moduledoc """
  Tracks and reports progress for long-running operations.
  """
  
  use GenServer
  
  def report_progress(execution_id, progress_data) do
    GenServer.cast(__MODULE__, {:progress, execution_id, progress_data})
  end
  
  def handle_cast({:progress, execution_id, data}, state) do
    # Get session for this execution
    case get_session_for_execution(execution_id) do
      {:ok, session_id} ->
        # Format progress event
        event = %{
          type: :execution_progress,
          execution_id: execution_id,
          progress: data.percentage,
          message: data.message,
          metadata: data[:metadata] || %{}
        }
        
        # Broadcast to all clients
        EventBroadcaster.broadcast_to_session(session_id, event)
        
      _ ->
        # Log orphaned progress
        Logger.warn("Progress for unknown execution: #{execution_id}")
    end
    
    {:noreply, state}
  end
end
```

## Multi-Client Support

### Session Sharing

Multiple clients can share the same session:

```elixir
defmodule Arbor.Integration.SessionSharing do
  @moduledoc """
  Enables multiple clients to share a session.
  """
  
  alias Arbor.Gateway
  alias Arbor.Security
  
  @doc """
  Create a shareable session token.
  """
  def create_share_token(session_id, constraints \\ %{}) do
    with {:ok, session} <- Gateway.get_session(session_id),
         :ok <- validate_share_permission(session) do
      
      # Create limited capability for shared access
      {:ok, share_cap} = Security.create_derived_capability(
        session.capabilities,
        Map.merge(%{
          max_operations: 100,
          expires_in: :timer.hours(24),
          read_only: false
        }, constraints)
      )
      
      # Generate share token
      token = generate_secure_token()
      store_share_token(token, session_id, share_cap)
      
      {:ok, token}
    end
  end
  
  @doc """
  Join existing session with share token.
  """
  def join_with_token(token, client_info) do
    with {:ok, share_data} <- validate_share_token(token),
         {:ok, session} <- Gateway.get_session(share_data.session_id) do
      
      # Register new client
      Gateway.SessionManager.register_client(
        share_data.session_id,
        Map.put(client_info, :capabilities, share_data.capabilities)
      )
      
      {:ok, %{
        session_id: share_data.session_id,
        capabilities: share_data.capabilities,
        shared: true
      }}
    end
  end
end
```

### Client Coordination

Coordinating actions across multiple clients:

```elixir
defmodule Arbor.Integration.ClientCoordinator do
  @moduledoc """
  Coordinates operations across multiple clients.
  """
  
  use GenServer
  
  def coordinate_operation(session_id, operation, required_confirmations \\ 1) do
    GenServer.call(__MODULE__, {
      :coordinate,
      session_id,
      operation,
      required_confirmations
    })
  end
  
  def handle_call({:coordinate, session_id, operation, required}, _from, state) do
    # Notify all clients
    event = %{
      type: :coordination_request,
      operation: operation,
      requires_confirmations: required,
      coordination_id: generate_coordination_id()
    }
    
    EventBroadcaster.broadcast_to_session(session_id, event)
    
    # Wait for confirmations
    case wait_for_confirmations(event.coordination_id, required) do
      {:ok, confirmations} ->
        {:reply, {:ok, confirmations}, state}
        
      {:error, :timeout} ->
        {:reply, {:error, :coordination_timeout}, state}
    end
  end
end
```

## Implementation Guidelines

### 1. Client Initialization Pattern

```elixir
# Standard client initialization flow
def initialize_client(type, auth, opts \\ []) do
  with {:ok, session_data} <- Gateway.create_session(type, auth, opts),
       :ok <- setup_event_handling(session_data),
       :ok <- register_client_specifics(type, session_data) do
    
    %{
      session_id: session_data.session_id,
      capabilities: session_data.capabilities,
      ready: true
    }
  end
end
```

### 2. Command Execution Pattern

```elixir
# Unified command execution with progress
def execute_with_progress(session, command, args) do
  case Gateway.execute_command(session.id, command, args) do
    {:ok, :async, %{execution_id: id}} ->
      # Track async execution
      track_execution(id)
      {:async, id}
      
    {:ok, result} ->
      # Immediate result
      {:ok, result}
      
    {:error, _} = error ->
      handle_command_error(error)
  end
end
```

### 3. Security-First Pattern

```elixir
# Always validate before execution
def secure_operation(session, operation, args) do
  with :ok <- validate_capability(session, operation),
       :ok <- check_constraints(session, operation, args),
       :ok <- audit_if_required(session, operation) do
    perform_operation(operation, args)
  end
end
```

### 4. Event Handling Pattern

```elixir
# Centralized event handling
def handle_session_event(event) do
  case event.type do
    :execution_progress ->
      update_progress_display(event)
      
    :security_violation ->
      handle_security_event(event)
      
    :coordination_request ->
      prompt_user_confirmation(event)
      
    _ ->
      log_event(event)
  end
end
```

### 5. Error Recovery Pattern

```elixir
# Graceful error handling with recovery
def with_recovery(operation, opts \\ []) do
  max_retries = Keyword.get(opts, :max_retries, 3)
  
  Stream.repeatedly(fn -> operation.() end)
  |> Stream.transform(0, fn
    {:ok, result}, _count ->
      {[{:ok, result}], :halt}
      
    {:error, reason}, count when count < max_retries ->
      Process.sleep(exponential_backoff(count))
      {[], count + 1}
      
    {:error, reason}, _count ->
      {[{:error, {:max_retries_exceeded, reason}}], :halt}
  end)
  |> Enum.take(1)
  |> List.first()
end
```

## Testing Integration

### Integration Test Pattern

```elixir
defmodule Arbor.IntegrationTest do
  use ExUnit.Case
  
  setup do
    # Start all required services
    start_supervised!(Arbor.Security.Supervisor)
    start_supervised!(Arbor.Gateway)
    start_supervised!(Arbor.AgentPool.Supervisor)
    
    # Create test session
    {:ok, session} = create_test_session()
    
    %{session: session}
  end
  
  test "multi-client coordination", %{session: session} do
    # Connect multiple clients
    {:ok, cli_client} = connect_cli_client(session.id)
    {:ok, web_client} = connect_web_client(session.id)
    
    # Execute command from CLI
    {:async, exec_id} = execute_command(cli_client, "analyze", %{})
    
    # Verify web client receives progress
    assert_receive {:web_event, %{type: :execution_progress}}
  end
  
  test "security violation handling", %{session: session} do
    # Attempt unauthorized operation
    result = execute_command(session, "dangerous_op", %{})
    
    assert {:error, :security_violation} = result
    assert_receive {:security_event, %{type: :violation}}
  end
end
```

## Migration Strategy

### Phased Integration Approach

1. **Phase 1: Gateway Foundation**
   - Implement core Gateway API
   - Add session management
   - Basic security integration

2. **Phase 2: Client Migration**
   - Migrate CLI to gateway pattern
   - Add WebSocket support for web clients
   - Implement API endpoints

3. **Phase 3: Advanced Features**
   - Multi-client coordination
   - Session sharing
   - Advanced security policies

4. **Phase 4: Optimization**
   - Performance tuning
   - Caching strategies
   - Load distribution

Each phase maintains backward compatibility while progressively enhancing the integration capabilities of the system.