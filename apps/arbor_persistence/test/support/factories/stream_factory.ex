defmodule Arbor.Persistence.StreamFactory do
  @moduledoc """
  Advanced stream factory for generating realistic event streams organized by aggregate.

  This factory builds upon FactoryHelpers and AgentFactory to create complex
  event stream scenarios that mirror real distributed system patterns in Arbor.

  ## Features

  - Aggregate-organized event streams (agent, session, system)
  - Proper event sequencing with causation relationships
  - Event versioning and positioning metadata
  - Cross-stream correlation patterns for distributed scenarios
  - Realistic temporal ordering and dependencies

  ## Usage

      use Arbor.Persistence.FastCase
      import Arbor.Persistence.StreamFactory
      
      test "multi-stream coordination", %{store: store} do
        # Create coordinated agent lifecycle streams
        streams = create_coordinated_agent_streams(3, 
          session_id: "coordination-session",
          correlation_id: "workflow-123"
        )
        
        # Store all streams
        for {stream_id, events} <- streams do
          {:ok, _} = Store.append_events(stream_id, events, -1, store)
        end
        
        # Validate cross-stream causation
        assert_cross_stream_causation(streams, store)
      end
  """

  import Arbor.Persistence.FactoryHelpers
  import Arbor.Persistence.AgentFactory
  import Arbor.Persistence.FastCase, only: [unique_stream_id: 1, build_test_event: 2]

  alias Arbor.Contracts.Events.Event

  @doc """
  Creates coordinated agent lifecycle streams with proper causation chains.

  Generates multiple agent streams where events are properly ordered and 
  correlated to simulate realistic distributed coordination scenarios.

  ## Parameters
  - `agent_count` - Number of agents to create streams for
  - `opts` - Configuration options

  ## Options
  - `:session_id` - Shared session for all agents
  - `:correlation_id` - Root correlation ID for the workflow
  - `:coordinator_type` - Type of coordination pattern (:hierarchical, :peer_to_peer)
  - `:temporal_spread_ms` - Time spread between events (default: 1000ms)
  - `:failure_probability` - Probability of agent failures (default: 0.1)

  ## Returns
  Map of `%{stream_id => [events]}` representing coordinated streams

  ## Examples

      # Simple coordination
      streams = create_coordinated_agent_streams(3)
      
      # Complex workflow with failure scenarios
      streams = create_coordinated_agent_streams(5,
        session_id: "distributed-task",
        correlation_id: "workflow-456",
        coordinator_type: :hierarchical,
        temporal_spread_ms: 2000,
        failure_probability: 0.2
      )
  """
  def create_coordinated_agent_streams(agent_count, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, unique_stream_id("session"))

    correlation_id =
      Keyword.get(opts, :correlation_id, "workflow_#{System.unique_integer([:positive])}")

    coordinator_type = Keyword.get(opts, :coordinator_type, :hierarchical)
    temporal_spread_ms = Keyword.get(opts, :temporal_spread_ms, 1000)
    failure_probability = Keyword.get(opts, :failure_probability, 0.1)

    base_time = DateTime.utc_now()

    # Create session initiation stream
    session_stream = create_session_stream(session_id, correlation_id, base_time)

    # Create agent streams based on coordination type
    agent_streams =
      case coordinator_type do
        :hierarchical ->
          create_hierarchical_agent_streams(
            agent_count,
            session_id,
            correlation_id,
            base_time,
            temporal_spread_ms,
            failure_probability
          )

        :peer_to_peer ->
          create_peer_to_peer_agent_streams(
            agent_count,
            session_id,
            correlation_id,
            base_time,
            temporal_spread_ms,
            failure_probability
          )
      end

    # Create coordination command stream
    coordination_stream =
      create_coordination_command_stream(session_id, correlation_id, agent_streams, base_time)

    Map.merge(%{session_id => session_stream, "gateway" => coordination_stream}, agent_streams)
  end

  @doc """
  Creates realistic event stream templates for common scenarios.

  Provides pre-built stream patterns for typical Arbor workflows.

  ## Parameters
  - `template_type` - Type of scenario template
  - `opts` - Configuration options

  ## Template Types
  - `:code_analysis_workflow` - Complete code analysis pipeline
  - `:multi_agent_task` - Distributed task execution
  - `:agent_recovery_scenario` - Failure and recovery pattern
  - `:session_lifecycle` - Full session with multiple operations
  - `:security_audit_flow` - Security scanning workflow

  ## Examples

      # Code analysis pipeline
      streams = create_stream_template(:code_analysis_workflow,
        repository_url: "https://github.com/example/repo",
        analysis_depth: :comprehensive
      )
      
      # Failure recovery scenario
      streams = create_stream_template(:agent_recovery_scenario,
        failure_type: :network_partition,
        recovery_strategy: :restart_cascade
      )
  """
  def create_stream_template(template_type, opts \\ []) do
    case template_type do
      :code_analysis_workflow ->
        create_code_analysis_workflow_streams(opts)

      :multi_agent_task ->
        create_multi_agent_task_streams(opts)

      :agent_recovery_scenario ->
        create_agent_recovery_scenario_streams(opts)

      :session_lifecycle ->
        create_session_lifecycle_streams(opts)

      :security_audit_flow ->
        create_security_audit_flow_streams(opts)

      _ ->
        raise ArgumentError, "Unknown template type: #{template_type}"
    end
  end

  @doc """
  Creates event streams with realistic temporal patterns.

  Generates events with realistic timing patterns including:
  - Burst activity periods
  - Idle periods
  - Gradual ramp-up/down
  - Concurrent event clusters

  ## Parameters
  - `pattern_type` - Type of temporal pattern
  - `duration_minutes` - Total duration to simulate
  - `opts` - Configuration options

  ## Pattern Types
  - `:business_hours` - Activity during business hours, quiet nights
  - `:batch_processing` - Periodic high-activity bursts
  - `:real_time_streaming` - Steady stream with occasional spikes
  - `:development_cycle` - Development workflow patterns

  ## Examples

      # Simulate 8 hours of business hour activity
      streams = create_temporal_pattern_streams(:business_hours, 480,
        timezone: "America/New_York",
        activity_level: :high
      )
  """
  def create_temporal_pattern_streams(pattern_type, duration_minutes, opts \\ []) do
    base_time = Keyword.get(opts, :start_time, DateTime.utc_now())

    case pattern_type do
      :business_hours ->
        create_business_hours_pattern(base_time, duration_minutes, opts)

      :batch_processing ->
        create_batch_processing_pattern(base_time, duration_minutes, opts)

      :real_time_streaming ->
        create_real_time_streaming_pattern(base_time, duration_minutes, opts)

      :development_cycle ->
        create_development_cycle_pattern(base_time, duration_minutes, opts)

      _ ->
        raise ArgumentError, "Unknown pattern type: #{pattern_type}"
    end
  end

  @doc """
  Creates cross-stream correlation scenarios for testing distributed tracing.

  Generates multiple related streams where events have proper correlation
  and causation relationships across stream boundaries.

  ## Parameters
  - `scenario_type` - Type of correlation scenario
  - `opts` - Configuration options

  ## Scenario Types
  - `:distributed_transaction` - Events that form a distributed transaction
  - `:saga_pattern` - Long-running saga with compensation
  - `:event_choreography` - Event-driven choreography pattern
  - `:request_response_chain` - Request flowing through multiple services

  ## Examples

      # Distributed transaction across multiple agents
      streams = create_correlation_scenario(:distributed_transaction,
        transaction_id: "tx_456",
        participants: [:account_service, :payment_service, :notification_service]
      )
      
      # Saga with compensation
      streams = create_correlation_scenario(:saga_pattern,
        saga_id: "saga_789",
        steps: [:reserve_inventory, :charge_payment, :ship_order],
        compensation_probability: 0.15
      )
  """
  def create_correlation_scenario(scenario_type, opts \\ []) do
    case scenario_type do
      :distributed_transaction ->
        create_distributed_transaction_streams(opts)

      :saga_pattern ->
        create_saga_pattern_streams(opts)

      :event_choreography ->
        create_event_choreography_streams(opts)

      :request_response_chain ->
        create_request_response_chain_streams(opts)

      _ ->
        raise ArgumentError, "Unknown scenario type: #{scenario_type}"
    end
  end

  # Private implementation functions

  defp create_session_stream(session_id, correlation_id, base_time) do
    session_event =
      session_created_event(session_id,
        user_id: "test_user",
        purpose: "Coordinated agent workflow",
        correlation_id: correlation_id
      )

    [
      %Event{
        session_event
        | timestamp: base_time,
          correlation_id: correlation_id,
          stream_version: 0
      }
    ]
  end

  defp create_hierarchical_agent_streams(
         agent_count,
         session_id,
         correlation_id,
         base_time,
         temporal_spread_ms,
         failure_probability
       ) do
    # Create coordinator first
    coordinator_id = unique_stream_id("coordinator")

    coordinator_events =
      create_agent_lifecycle_with_timing(
        coordinator_id,
        :coordinator,
        session_id,
        correlation_id,
        base_time,
        0
      )

    # Create worker agents that report to coordinator
    worker_streams =
      1..(agent_count - 1)
      |> Enum.map(fn i ->
        agent_id = unique_stream_id("worker")

        agent_type =
          Enum.at([:code_analyzer, :test_generator, :documentation_writer], rem(i - 1, 3))

        # Stagger agent starts
        start_time = DateTime.add(base_time, i * temporal_spread_ms, :millisecond)

        agent_events =
          create_agent_lifecycle_with_timing(
            agent_id,
            agent_type,
            session_id,
            correlation_id,
            start_time,
            i,
            parent_id: coordinator_id
          )

        # Add failure events if probability triggers
        final_events =
          if :rand.uniform() < failure_probability do
            add_failure_recovery_events(agent_events, start_time, temporal_spread_ms)
          else
            agent_events
          end

        {agent_id, final_events}
      end)
      |> Map.new()

    Map.put(worker_streams, coordinator_id, coordinator_events)
  end

  defp create_peer_to_peer_agent_streams(
         agent_count,
         session_id,
         correlation_id,
         base_time,
         temporal_spread_ms,
         _failure_probability
       ) do
    1..agent_count
    |> Enum.map(fn i ->
      agent_id = unique_stream_id("peer_agent")
      agent_type = Enum.at([:llm, :code_analyzer, :tool_executor], rem(i - 1, 3))

      # Stagger starts but make them more concurrent than hierarchical
      start_time = DateTime.add(base_time, div(i * temporal_spread_ms, 2), :millisecond)

      agent_events =
        create_agent_lifecycle_with_timing(
          agent_id,
          agent_type,
          session_id,
          correlation_id,
          start_time,
          i
        )

      {agent_id, agent_events}
    end)
    |> Map.new()
  end

  defp create_coordination_command_stream(session_id, correlation_id, agent_streams, base_time) do
    agent_ids = Map.keys(agent_streams) |> Enum.reject(&(&1 == session_id))

    commands = [
      # Initial coordination setup
      command_received_event(:setup_coordination,
        command_id: "cmd_setup_#{System.unique_integer([:positive])}",
        session_id: session_id,
        agent_ids: agent_ids,
        correlation_id: correlation_id
      )
      |> put_event_timing(base_time, 1),

      # Task distribution commands
      command_received_event(:distribute_tasks,
        command_id: "cmd_distribute_#{System.unique_integer([:positive])}",
        session_id: session_id,
        task_count: length(agent_ids),
        correlation_id: correlation_id
      )
      |> put_event_timing(DateTime.add(base_time, 2000, :millisecond), 2),

      # Monitoring command
      command_received_event(:monitor_progress,
        command_id: "cmd_monitor_#{System.unique_integer([:positive])}",
        session_id: session_id,
        correlation_id: correlation_id
      )
      |> put_event_timing(DateTime.add(base_time, 5000, :millisecond), 3)
    ]

    # Add proper stream versioning
    commands
    |> Enum.with_index()
    |> Enum.map(fn {event, index} ->
      %Event{event | stream_version: index}
    end)
  end

  defp create_agent_lifecycle_with_timing(
         agent_id,
         agent_type,
         session_id,
         correlation_id,
         start_time,
         offset,
         opts \\ []
       ) do
    parent_id = Keyword.get(opts, :parent_id)

    # Create base lifecycle events
    events =
      agent_lifecycle_events(agent_id,
        agent_type: agent_type,
        session_id: session_id,
        correlation_id: correlation_id,
        parent_id: parent_id,
        message_count: 2
      )

    # Apply realistic timing
    events
    |> Enum.with_index()
    |> Enum.map(fn {event, index} ->
      # Each event 500ms apart, plus offset for this agent
      event_time = DateTime.add(start_time, index * 500 + offset * 100, :millisecond)
      %Event{event | timestamp: event_time}
    end)
  end

  defp add_failure_recovery_events(agent_events, start_time, temporal_spread_ms) do
    failure_time = DateTime.add(start_time, temporal_spread_ms + 2000, :millisecond)
    recovery_time = DateTime.add(failure_time, 3000, :millisecond)

    agent_id = hd(agent_events).aggregate_id
    correlation_id = hd(agent_events).correlation_id

    failure_event =
      build_test_event(:agent_failed,
        aggregate_id: agent_id,
        stream_id: agent_id,
        data: %{
          agent_id: agent_id,
          failure_reason: "timeout",
          failed_at: failure_time
        }
      )
      |> put_event_timing(failure_time, length(agent_events))
      |> put_correlation(correlation_id)

    recovery_event =
      build_test_event(:agent_recovered,
        aggregate_id: agent_id,
        stream_id: agent_id,
        data: %{
          agent_id: agent_id,
          recovery_strategy: "restart",
          recovered_at: recovery_time
        }
      )
      |> put_event_timing(recovery_time, length(agent_events) + 1)
      |> put_correlation(correlation_id)

    agent_events ++ [failure_event, recovery_event]
  end

  defp put_event_timing(event, timestamp, version) do
    %Event{event | timestamp: timestamp, stream_version: version}
  end

  defp put_correlation(event, correlation_id) do
    %Event{event | correlation_id: correlation_id}
  end

  # Template implementations (stubs for now - can be expanded)

  defp create_code_analysis_workflow_streams(_opts) do
    # Implementation would create realistic code analysis pipeline
    %{}
  end

  defp create_multi_agent_task_streams(_opts) do
    # Implementation would create distributed task execution scenario
    %{}
  end

  defp create_agent_recovery_scenario_streams(_opts) do
    # Implementation would create failure/recovery scenarios
    %{}
  end

  defp create_session_lifecycle_streams(_opts) do
    # Implementation would create complete session with multiple operations
    %{}
  end

  defp create_security_audit_flow_streams(_opts) do
    # Implementation would create security scanning workflow
    %{}
  end

  # Temporal pattern implementations (stubs for now - can be expanded)

  defp create_business_hours_pattern(_base_time, _duration_minutes, _opts) do
    # Implementation would simulate business hours activity patterns
    %{}
  end

  defp create_batch_processing_pattern(_base_time, _duration_minutes, _opts) do
    # Implementation would simulate batch processing patterns
    %{}
  end

  defp create_real_time_streaming_pattern(_base_time, _duration_minutes, _opts) do
    # Implementation would simulate real-time streaming patterns
    %{}
  end

  defp create_development_cycle_pattern(_base_time, _duration_minutes, _opts) do
    # Implementation would simulate development workflow patterns
    %{}
  end

  # Correlation scenario implementations (stubs for now - can be expanded)

  defp create_distributed_transaction_streams(_opts) do
    # Implementation would create distributed transaction scenario
    %{}
  end

  defp create_saga_pattern_streams(_opts) do
    # Implementation would create saga pattern scenario
    %{}
  end

  defp create_event_choreography_streams(_opts) do
    # Implementation would create event choreography scenario
    %{}
  end

  defp create_request_response_chain_streams(_opts) do
    # Implementation would create request/response chain scenario
    %{}
  end
end
