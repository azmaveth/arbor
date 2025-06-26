defmodule Arbor.Persistence.FactoryHelpers do
  @moduledoc """
  Foundation factory helpers that extend the existing test infrastructure.

  This module provides domain-specific presets and builders that extend
  the existing `build_test_event` functionality while maintaining 100%
  backward compatibility.

  ## Usage

      use Arbor.Persistence.FastCase
      import Arbor.Persistence.FactoryHelpers
      
      test "agent lifecycle", %{store: store} do
        events = agent_lifecycle_events("agent-123")
        {:ok, _} = Store.append_events("agent-123", events, -1, store)
        
        # Use with existing utilities
        assert_event_sequence("agent-123", [
          :agent_started, :agent_configured, :agent_activated
        ], store)
      end
  """

  alias Arbor.Contracts.Events.Event

  # Import existing helpers to extend them
  import Arbor.Persistence.FastCase, only: [build_test_event: 2, unique_stream_id: 1]

  @doc """
  Creates a realistic agent started event with proper AI model configuration.

  ## Options
  - `:agent_type` - Agent type (default: :llm)
  - `:model` - AI model name (default: "claude-3.5-sonnet")
  - `:capabilities` - List of capabilities (default: text generation)
  - `:session_id` - Associated session ID
  - `:node` - Node identifier
  - `:parent_id` - Parent agent for hierarchical scenarios

  ## Examples

      event = agent_started_event("agent-123")
      event = agent_started_event("agent-456", 
        model: "gpt-4", 
        agent_type: :code_analyzer,
        session_id: "session-789"
      )
  """
  def agent_started_event(agent_id, opts \\ []) do
    agent_type = Keyword.get(opts, :agent_type, :llm)
    model = Keyword.get(opts, :model, "claude-3.5-sonnet")
    session_id = Keyword.get(opts, :session_id, unique_stream_id("session"))
    node = Keyword.get(opts, :node, :arbor@localhost)
    parent_id = Keyword.get(opts, :parent_id)

    capabilities =
      Keyword.get(opts, :capabilities, [
        "text_generation",
        "analysis",
        "reasoning"
      ])

    data = %{
      agent_id: agent_id,
      agent_type: agent_type,
      session_id: session_id,
      node: node,
      module: agent_module_for_type(agent_type),
      model: model,
      capabilities: capabilities,
      config: %{
        temperature: 0.7,
        max_tokens: 4000,
        timeout_ms: 30_000
      },
      metadata: %{
        created_by: "test_factory",
        environment: "test"
      }
    }

    data = if parent_id, do: Map.put(data, :parent_id, parent_id), else: data

    build_test_event(:agent_started,
      aggregate_id: agent_id,
      stream_id: agent_id,
      data: data
    )
  end

  @doc """
  Creates an agent configured event with realistic configuration updates.
  """
  def agent_configured_event(agent_id, opts \\ []) do
    config_updates =
      Keyword.get(opts, :config, %{
        temperature: 0.8,
        max_tokens: 2048,
        system_prompt:
          "You are a helpful AI assistant specialized in #{Keyword.get(opts, :specialty, "general tasks")}."
      })

    performance_settings =
      Keyword.get(opts, :performance, %{
        batch_size: 10,
        concurrent_tasks: 3,
        memory_limit_mb: 512
      })

    build_test_event(:agent_configured,
      aggregate_id: agent_id,
      stream_id: agent_id,
      data: %{
        agent_id: agent_id,
        config_updates: config_updates,
        performance_settings: performance_settings,
        configured_by: Keyword.get(opts, :configured_by, "system"),
        configuration_version: Keyword.get(opts, :version, "1.0.0")
      }
    )
  end

  @doc """
  Creates an agent activated event indicating the agent is ready for work.
  """
  def agent_activated_event(agent_id, opts \\ []) do
    build_test_event(:agent_activated,
      aggregate_id: agent_id,
      stream_id: agent_id,
      data: %{
        agent_id: agent_id,
        status: :active,
        activation_time_ms: Keyword.get(opts, :activation_time, 150),
        memory_usage_bytes: Keyword.get(opts, :memory_usage, 64_000_000),
        ready_at: DateTime.utc_now(),
        health_status: :healthy,
        # Include fields that should be preserved in aggregate state
        priority: Keyword.get(opts, :priority, :normal)
      }
    )
  end

  @doc """
  Creates an agent message sent event for communication tracking.
  """
  def agent_message_sent_event(agent_id, opts \\ []) do
    message_type = Keyword.get(opts, :message_type, :task_request)
    recipient = Keyword.get(opts, :recipient, "user")

    build_test_event(:agent_message_sent,
      aggregate_id: agent_id,
      stream_id: agent_id,
      data: %{
        agent_id: agent_id,
        message_type: message_type,
        recipient: recipient,
        message_size_bytes: Keyword.get(opts, :size, 1024),
        priority: Keyword.get(opts, :priority, :normal),
        sent_at: DateTime.utc_now()
      }
    )
  end

  @doc """
  Creates an agent stopped event with proper cleanup and metrics.
  """
  def agent_stopped_event(agent_id, opts \\ []) do
    reason = Keyword.get(opts, :reason, :completed)
    exit_status = Keyword.get(opts, :exit_status, :success)
    tasks_completed = Keyword.get(opts, :tasks_completed, 3)

    build_test_event(:agent_stopped,
      aggregate_id: agent_id,
      stream_id: agent_id,
      data: %{
        agent_id: agent_id,
        reason: reason,
        exit_status: exit_status,
        run_duration_ms: Keyword.get(opts, :duration, 5000),
        tasks_completed: tasks_completed,
        memory_peak_bytes: Keyword.get(opts, :memory_peak, 128_000_000),
        stopped_at: DateTime.utc_now(),
        # Add the tasks_completed field to ensure it gets merged into aggregate state
        state_changes: %{
          tasks_completed: tasks_completed
        }
      }
    )
  end

  @doc """
  Creates a complete agent lifecycle event sequence.

  Generates a realistic sequence of events for a complete agent lifecycle:
  started → configured → activated → (messages) → stopped

  ## Options
  - `:message_count` - Number of message events (default: 2)
  - `:session_id` - Associated session ID
  - `:agent_type` - Type of agent (default: :llm)
  - `:model` - AI model name
  - All other options are passed to individual event builders

  ## Examples

      events = agent_lifecycle_events("agent-123")
      events = agent_lifecycle_events("agent-456", 
        message_count: 5,
        agent_type: :code_analyzer,
        session_id: "session-789"
      )
  """
  def agent_lifecycle_events(agent_id, opts \\ []) do
    message_count = Keyword.get(opts, :message_count, 2)

    base_events = [
      agent_started_event(agent_id, opts),
      agent_configured_event(agent_id, opts),
      agent_activated_event(agent_id, opts)
    ]

    message_events =
      1..message_count
      |> Enum.map(fn i ->
        agent_message_sent_event(
          agent_id,
          Keyword.merge(opts, message_type: "message_#{i}")
        )
      end)

    stop_event =
      agent_stopped_event(
        agent_id,
        Keyword.merge(opts, tasks_completed: message_count)
      )

    all_events = base_events ++ message_events ++ [stop_event]

    # Set proper stream versions and correlation IDs
    correlation_id = Keyword.get(opts, :correlation_id, "lifecycle_#{agent_id}")

    all_events
    |> Enum.with_index()
    |> Enum.map(fn {event, index} ->
      %Event{
        event
        | stream_version: index,
          correlation_id: correlation_id,
          causation_id: if(index > 0, do: Enum.at(all_events, index - 1).id, else: nil)
      }
    end)
  end

  @doc """
  Creates a session created event with realistic session data.
  """
  def session_created_event(session_id, opts \\ []) do
    user_id = Keyword.get(opts, :user_id, "user_#{System.unique_integer([:positive])}")
    purpose = Keyword.get(opts, :purpose, "AI-assisted development session")

    build_test_event(:session_created,
      aggregate_id: session_id,
      stream_id: session_id,
      data: %{
        session_id: session_id,
        user_id: user_id,
        purpose: purpose,
        max_agents: Keyword.get(opts, :max_agents, 10),
        timeout_minutes: Keyword.get(opts, :timeout, 60),
        context:
          Keyword.get(opts, :context, %{
            working_directory: "/tmp/arbor_session",
            language: "elixir",
            project_type: "umbrella"
          }),
        capabilities:
          Keyword.get(opts, :capabilities, [
            "spawn_agent",
            "query_agents",
            "execute_commands"
          ])
      }
    )
  end

  @doc """
  Creates cluster-related events for distributed system testing.
  """
  def node_joined_event(node_name, opts \\ []) do
    build_test_event(:node_joined,
      aggregate_id: "cluster",
      stream_id: "cluster",
      data: %{
        node: node_name,
        node_info: %{
          hostname: Keyword.get(opts, :hostname, "localhost"),
          ip_address: Keyword.get(opts, :ip, "127.0.0.1"),
          port: Keyword.get(opts, :port, 4369),
          capabilities: Keyword.get(opts, :capabilities, ["agent_hosting", "coordination"]),
          resources: %{
            cpu_count: Keyword.get(opts, :cpu_count, 4),
            memory_gb: Keyword.get(opts, :memory_gb, 8),
            disk_gb: Keyword.get(opts, :disk_gb, 100)
          }
        },
        cluster_size: Keyword.get(opts, :cluster_size, 1),
        joined_at: DateTime.utc_now()
      }
    )
  end

  @doc """
  Creates gateway command events for testing command processing.
  """
  def command_received_event(command_type, opts \\ []) do
    command_id = Keyword.get(opts, :command_id, "cmd_#{System.unique_integer([:positive])}")

    command_data =
      case command_type do
        :spawn_agent ->
          %{
            agent_type: Keyword.get(opts, :agent_type, :llm),
            model: Keyword.get(opts, :model, "claude-3.5-sonnet"),
            session_id: Keyword.get(opts, :session_id, unique_stream_id("session"))
          }

        :query_agents ->
          %{
            filters: Keyword.get(opts, :filters, %{status: :active}),
            limit: Keyword.get(opts, :limit, 10)
          }

        :execute_agent_command ->
          %{
            agent_id: Keyword.get(opts, :agent_id, unique_stream_id("agent")),
            command: Keyword.get(opts, :command, "analyze_code"),
            parameters: Keyword.get(opts, :parameters, %{})
          }

        _ ->
          Keyword.get(opts, :data, %{})
      end

    build_test_event(:command_received,
      aggregate_id: command_id,
      stream_id: "gateway",
      data: %{
        command_id: command_id,
        command_type: command_type,
        command_data: command_data,
        received_at: DateTime.utc_now(),
        source: Keyword.get(opts, :source, "test_client")
      }
    )
  end

  # Private helper functions

  defp agent_module_for_type(:llm), do: "Arbor.Core.LLMAgent"
  defp agent_module_for_type(:code_analyzer), do: "Arbor.Core.CodeAnalyzerAgent"
  defp agent_module_for_type(:coordinator), do: "Arbor.Core.CoordinatorAgent"
  defp agent_module_for_type(:tool_executor), do: "Arbor.Core.ToolExecutorAgent"
  defp agent_module_for_type(_), do: "Arbor.Core.GenericAgent"
end
