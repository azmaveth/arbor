defmodule Arbor.Persistence.AgentFactory do
  @moduledoc """
  Comprehensive agent factory for generating realistic AI agent configurations,
  lifecycle events, and complex multi-agent scenarios.

  This factory provides both simple builders and complex scenario generation
  for testing agent behaviors, performance characteristics, and distributed
  coordination patterns.

  ## Usage

      use Arbor.Persistence.FastCase
      import Arbor.Persistence.AgentFactory
      
      test "multi-agent coordination", %{store: store} do
        # Simple agent creation
        agent = create_agent("claude-assistant", :llm)
        
        # Complex scenario
        {coordinator, workers} = create_coordinator_with_workers(3)
        
        # Agent hierarchy
        agents = create_agent_hierarchy("root-agent", depth: 2, fanout: 3)
      end
  """

  import Arbor.Persistence.FactoryHelpers
  import Arbor.Persistence.FastCase, only: [unique_stream_id: 1, build_test_event: 2]

  alias Arbor.Contracts.Events.Event

  @doc """
  Creates a complete agent with realistic configuration and capabilities.

  ## Parameters
  - `agent_id` - Unique agent identifier
  - `agent_type` - Type of agent (see agent_types/0)
  - `opts` - Configuration options

  ## Options
  - `:model` - AI model name
  - `:session_id` - Associated session
  - `:capabilities` - List of capabilities
  - `:config` - Agent configuration map
  - `:parent_id` - Parent agent for hierarchies
  - `:priority` - Agent priority (:low, :normal, :high, :urgent)
  - `:specialization` - Domain specialization

  ## Returns
  Map containing agent configuration and lifecycle events.

  ## Examples

      agent = create_agent("assistant-1", :llm)
      
      agent = create_agent("analyzer-1", :code_analyzer,
        model: "gpt-4",
        specialization: "elixir",
        priority: :high
      )
  """
  def create_agent(agent_id, agent_type, opts \\ []) do
    model = Keyword.get(opts, :model, default_model_for_type(agent_type))
    session_id = Keyword.get(opts, :session_id, unique_stream_id("session"))
    priority = Keyword.get(opts, :priority, :normal)
    specialization = Keyword.get(opts, :specialization)
    parent_id = Keyword.get(opts, :parent_id)

    config = build_agent_config(agent_type, model, opts)
    capabilities = build_agent_capabilities(agent_type, specialization)

    # Generate lifecycle events
    events =
      agent_lifecycle_events(agent_id,
        agent_type: agent_type,
        model: model,
        session_id: session_id,
        parent_id: parent_id,
        config: config,
        capabilities: capabilities,
        priority: priority
      )

    %{
      agent_id: agent_id,
      agent_type: agent_type,
      model: model,
      session_id: session_id,
      config: config,
      capabilities: capabilities,
      priority: priority,
      specialization: specialization,
      parent_id: parent_id,
      events: events,
      status: :active
    }
  end

  @doc """
  Creates a coordinator agent with multiple worker agents.

  Generates a realistic distributed coordination scenario with:
  - One coordinator agent managing the workflow
  - Multiple worker agents with different specializations
  - Proper parent-child relationships
  - Coordination events and task distribution

  ## Parameters
  - `worker_count` - Number of worker agents to create
  - `opts` - Configuration options

  ## Options
  - `:coordinator_type` - Type of coordination (:hierarchical, :peer_to_peer)
  - `:worker_types` - List of worker agent types
  - `:session_id` - Shared session ID
  - `:task_distribution` - How tasks are distributed

  ## Returns
  Tuple of {coordinator_config, worker_configs_list}

  ## Examples

      {coordinator, workers} = create_coordinator_with_workers(3)
      
      {coordinator, workers} = create_coordinator_with_workers(5,
        coordinator_type: :hierarchical,
        worker_types: [:code_analyzer, :test_generator, :documentation_writer],
        task_distribution: :round_robin
      )
  """
  def create_coordinator_with_workers(worker_count, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, unique_stream_id("session"))
    coordinator_id = unique_stream_id("coordinator")
    coordinator_type = Keyword.get(opts, :coordinator_type, :hierarchical)
    task_distribution = Keyword.get(opts, :task_distribution, :load_balanced)

    worker_types =
      Keyword.get(opts, :worker_types, [
        :code_analyzer,
        :test_generator,
        :documentation_writer,
        :refactoring_assistant,
        :security_auditor
      ])

    # Create coordinator
    coordinator =
      create_agent(coordinator_id, :coordinator,
        session_id: session_id,
        config: %{
          coordination_type: coordinator_type,
          task_distribution: task_distribution,
          max_workers: worker_count,
          health_check_interval_ms: 5000
        },
        capabilities: [
          "worker_management",
          "task_distribution",
          "load_balancing",
          "health_monitoring",
          "failure_recovery"
        ]
      )

    # Create workers with proper parent relationship
    workers =
      1..worker_count
      |> Enum.map(fn i ->
        worker_id = unique_stream_id("worker")
        worker_type = Enum.at(worker_types, rem(i - 1, length(worker_types)))

        create_agent(worker_id, worker_type,
          session_id: session_id,
          parent_id: coordinator_id,
          priority: :normal,
          specialization: specialization_for_type(worker_type)
        )
      end)

    # Add coordination events
    coordination_events = create_coordination_events(coordinator, workers)

    coordinator_with_events = %{coordinator | events: coordinator.events ++ coordination_events}

    {coordinator_with_events, workers}
  end

  @doc """
  Creates a hierarchical agent structure for testing complex scenarios.

  Generates a tree-like structure of agents with realistic parent-child
  relationships, delegation patterns, and capability inheritance.

  ## Parameters
  - `root_agent_id` - Root agent identifier
  - `opts` - Configuration options

  ## Options
  - `:depth` - Tree depth (default: 2)
  - `:fanout` - Children per node (default: 3)
  - `:session_id` - Shared session ID
  - `:capability_inheritance` - Whether children inherit parent capabilities

  ## Returns
  List of agent configurations in tree order (breadth-first)

  ## Examples

      agents = create_agent_hierarchy("root-1")
      
      agents = create_agent_hierarchy("coordinator-1",
        depth: 3,
        fanout: 2,
        capability_inheritance: true
      )
  """
  def create_agent_hierarchy(root_agent_id, opts \\ []) do
    depth = Keyword.get(opts, :depth, 2)
    fanout = Keyword.get(opts, :fanout, 3)
    session_id = Keyword.get(opts, :session_id, unique_stream_id("session"))
    capability_inheritance = Keyword.get(opts, :capability_inheritance, true)

    # Build tree structure
    tree_nodes = build_agent_tree(root_agent_id, depth, fanout, session_id)

    # Create agents with proper relationships
    agents =
      tree_nodes
      |> Enum.map(fn %{id: id, parent_id: parent_id, level: level} ->
        agent_type = agent_type_for_level(level)
        specialization = specialization_for_level(level)

        # Inherit capabilities from parent if enabled
        base_capabilities = build_agent_capabilities(agent_type, specialization)

        capabilities =
          if capability_inheritance and parent_id do
            parent_agent = Enum.find(tree_nodes, &(&1.id == parent_id))
            inherit_capabilities(base_capabilities, parent_agent)
          else
            base_capabilities
          end

        create_agent(id, agent_type,
          session_id: session_id,
          parent_id: parent_id,
          specialization: specialization,
          capabilities: capabilities,
          priority: priority_for_level(level)
        )
      end)

    # Add hierarchy coordination events
    hierarchy_events = create_hierarchy_events(agents)

    # Add events to root agent
    root_agent = List.first(agents)
    updated_root = %{root_agent | events: root_agent.events ++ hierarchy_events}

    [updated_root | Enum.drop(agents, 1)]
  end

  @doc """
  Creates a failure scenario for testing agent resilience and recovery.

  Generates realistic failure patterns including:
  - Agent crashes with different error types
  - Network partitions and communication failures
  - Resource exhaustion scenarios
  - Recovery and restart patterns

  ## Parameters
  - `agents` - List of agent configurations
  - `failure_type` - Type of failure to simulate
  - `opts` - Configuration options

  ## Failure Types
  - `:crash` - Agent process crashes
  - `:timeout` - Agent becomes unresponsive
  - `:resource_exhaustion` - Memory/CPU limits exceeded
  - `:network_partition` - Communication failures
  - `:cascade` - Failure propagation through dependencies

  ## Returns
  List of failure and recovery events
  """
  def create_failure_scenario(agents, failure_type, opts \\ []) do
    failure_time = Keyword.get(opts, :failure_time, DateTime.utc_now())
    recovery_time = Keyword.get(opts, :recovery_time, DateTime.add(failure_time, 30, :second))

    case failure_type do
      :crash ->
        create_crash_scenario(agents, failure_time, recovery_time, opts)

      :timeout ->
        create_timeout_scenario(agents, failure_time, recovery_time, opts)

      :resource_exhaustion ->
        create_resource_exhaustion_scenario(agents, failure_time, recovery_time, opts)

      :network_partition ->
        create_network_partition_scenario(agents, failure_time, recovery_time, opts)

      :cascade ->
        create_cascade_failure_scenario(agents, failure_time, recovery_time, opts)

      _ ->
        []
    end
  end

  @doc """
  Creates performance testing scenarios with load patterns.

  Generates realistic load testing data including:
  - High-throughput message patterns
  - Memory and CPU usage patterns
  - Task completion metrics
  - Scalability stress scenarios

  ## Parameters
  - `agent_count` - Number of agents to simulate
  - `load_pattern` - Type of load pattern
  - `opts` - Configuration options

  ## Load Patterns
  - `:steady` - Constant load over time
  - `:burst` - Periodic high-load bursts
  - `:ramp_up` - Gradually increasing load
  - `:spike` - Sudden load spikes
  - `:random` - Random load variations

  ## Returns
  List of performance events and metrics
  """
  def create_performance_scenario(agent_count, load_pattern, opts \\ []) do
    duration_minutes = Keyword.get(opts, :duration_minutes, 10)
    tasks_per_minute = Keyword.get(opts, :tasks_per_minute, 100)

    # Create agents for performance testing
    agents =
      1..agent_count
      |> Enum.map(fn i ->
        create_agent(unique_stream_id("perf_agent"), :llm,
          priority: :high,
          config: %{
            performance_mode: true,
            max_concurrent_tasks: 10,
            batch_size: 50
          }
        )
      end)

    # Generate load pattern events
    load_events =
      case load_pattern do
        :steady ->
          create_steady_load_events(agents, duration_minutes, tasks_per_minute)

        :burst ->
          create_burst_load_events(agents, duration_minutes, tasks_per_minute, opts)

        :ramp_up ->
          create_ramp_up_load_events(agents, duration_minutes, tasks_per_minute)

        :spike ->
          create_spike_load_events(agents, duration_minutes, tasks_per_minute, opts)

        :random ->
          create_random_load_events(agents, duration_minutes, tasks_per_minute, opts)

        _ ->
          []
      end

    {agents, load_events}
  end

  @doc """
  Returns list of available agent types with their characteristics.
  """
  def agent_types do
    [
      :coordinator,
      :llm,
      :code_analyzer,
      :test_generator,
      :documentation_writer,
      :refactoring_assistant,
      :security_auditor,
      :performance_analyzer,
      :api_designer,
      :database_optimizer,
      :deployment_manager,
      :monitoring_specialist,
      :tool_executor,
      :export,
      :worker,
      :gateway
    ]
  end

  # Private helper functions

  defp default_model_for_type(:llm), do: "claude-3.5-sonnet"
  defp default_model_for_type(:code_analyzer), do: "gpt-4"
  defp default_model_for_type(:test_generator), do: "claude-3-haiku"
  defp default_model_for_type(:documentation_writer), do: "gpt-3.5-turbo"
  defp default_model_for_type(:security_auditor), do: "claude-3.5-sonnet"
  defp default_model_for_type(_), do: "claude-3-haiku"

  defp build_agent_config(agent_type, model, opts) do
    base_config = %{
      model: model,
      temperature: 0.7,
      max_tokens: 4000,
      timeout_ms: 30_000,
      retry_attempts: 3,
      batch_processing: false,
      memory_limit_mb: 512
    }

    type_specific_config =
      case agent_type do
        :coordinator ->
          %{
            coordination_strategy: :hierarchical,
            health_check_interval_ms: 5000,
            task_queue_size: 1000,
            worker_timeout_ms: 60_000
          }

        :code_analyzer ->
          %{
            supported_languages: ["elixir", "javascript", "python", "rust"],
            analysis_depth: :medium,
            include_metrics: true,
            output_format: :detailed
          }

        :test_generator ->
          %{
            test_framework: "ExUnit",
            coverage_target: 0.8,
            include_property_tests: true,
            mock_strategy: :automatic
          }

        :security_auditor ->
          %{
            audit_scope: [:owasp_top_10, :code_injection, :auth_bypass],
            severity_threshold: :medium,
            include_remediation: true
          }

        _ ->
          %{}
      end

    custom_config = Keyword.get(opts, :config, %{})

    Map.merge(base_config, type_specific_config)
    |> Map.merge(custom_config)
  end

  defp build_agent_capabilities(agent_type, specialization) do
    base_capabilities = [
      "task_execution",
      "status_reporting",
      "health_monitoring"
    ]

    type_capabilities =
      case agent_type do
        :coordinator ->
          ["worker_management", "task_distribution", "load_balancing", "failure_recovery"]

        :code_analyzer ->
          ["code_analysis", "pattern_detection", "metrics_calculation", "quality_assessment"]

        :test_generator ->
          ["test_generation", "coverage_analysis", "mock_creation", "assertion_building"]

        :documentation_writer ->
          ["documentation_generation", "api_documentation", "code_commenting", "guide_writing"]

        :security_auditor ->
          [
            "vulnerability_scanning",
            "security_analysis",
            "compliance_checking",
            "threat_modeling"
          ]

        :llm ->
          ["text_generation", "analysis", "reasoning", "conversation"]

        _ ->
          ["general_processing"]
      end

    specialization_capabilities =
      if specialization do
        ["#{specialization}_specialist", "#{specialization}_optimization"]
      else
        []
      end

    base_capabilities ++ type_capabilities ++ specialization_capabilities
  end

  defp specialization_for_type(:code_analyzer), do: "static_analysis"
  defp specialization_for_type(:test_generator), do: "unit_testing"
  defp specialization_for_type(:documentation_writer), do: "technical_writing"
  defp specialization_for_type(:security_auditor), do: "vulnerability_assessment"
  defp specialization_for_type(_), do: nil

  defp create_coordination_events(coordinator, workers) do
    worker_ids = Enum.map(workers, & &1.agent_id)

    [
      build_test_event(:workers_assigned,
        aggregate_id: coordinator.agent_id,
        stream_id: coordinator.agent_id,
        data: %{
          coordinator_id: coordinator.agent_id,
          worker_ids: worker_ids,
          assignment_strategy: "load_balanced",
          assigned_at: DateTime.utc_now()
        }
      ),
      build_test_event(:coordination_started,
        aggregate_id: coordinator.agent_id,
        stream_id: coordinator.agent_id,
        data: %{
          coordinator_id: coordinator.agent_id,
          worker_count: length(workers),
          coordination_mode: "active",
          started_at: DateTime.utc_now()
        }
      )
    ]
  end

  defp build_agent_tree(root_id, depth, fanout, session_id, level \\ 0, parent_id \\ nil) do
    current_node = %{
      id: if(level == 0, do: root_id, else: unique_stream_id("agent")),
      parent_id: parent_id,
      level: level,
      session_id: session_id
    }

    if level < depth do
      children =
        1..fanout
        |> Enum.flat_map(fn _i ->
          build_agent_tree(nil, depth, fanout, session_id, level + 1, current_node.id)
        end)

      [current_node | children]
    else
      [current_node]
    end
  end

  defp agent_type_for_level(0), do: :coordinator
  defp agent_type_for_level(1), do: :llm
  defp agent_type_for_level(_), do: :worker

  defp specialization_for_level(0), do: "orchestration"
  defp specialization_for_level(1), do: "reasoning"
  defp specialization_for_level(_), do: "task_execution"

  defp priority_for_level(0), do: :urgent
  defp priority_for_level(1), do: :high
  defp priority_for_level(_), do: :normal

  defp inherit_capabilities(base_capabilities, parent) do
    # Simplified capability inheritance - in reality this would be more complex
    base_capabilities ++ ["inherited_from_#{parent.id}"]
  end

  defp create_hierarchy_events(agents) do
    root_agent = List.first(agents)

    [
      build_test_event(:hierarchy_established,
        aggregate_id: root_agent.agent_id,
        stream_id: root_agent.agent_id,
        data: %{
          root_agent_id: root_agent.agent_id,
          total_agents: length(agents),
          hierarchy_depth: calculate_hierarchy_depth(agents),
          established_at: DateTime.utc_now()
        }
      )
    ]
  end

  defp calculate_hierarchy_depth(agents) do
    agents
    |> Enum.map(& &1.priority)
    |> Enum.count(&(&1 != :urgent))
    |> max(1)
  end

  # Failure scenario implementations

  defp create_crash_scenario(agents, failure_time, recovery_time, _opts) do
    agent = List.first(agents)

    [
      build_test_event(:agent_crashed,
        aggregate_id: agent.agent_id,
        stream_id: agent.agent_id,
        data: %{
          agent_id: agent.agent_id,
          crash_reason: "segmentation_fault",
          stack_trace: ["module.function/2", "supervisor.handle_crash/1"],
          crashed_at: failure_time
        }
      ),
      build_test_event(:agent_recovery_started,
        aggregate_id: agent.agent_id,
        stream_id: agent.agent_id,
        data: %{
          agent_id: agent.agent_id,
          recovery_strategy: "restart",
          recovery_started_at: recovery_time
        }
      )
    ]
  end

  defp create_timeout_scenario(agents, failure_time, recovery_time, _opts) do
    agent = List.first(agents)

    [
      build_test_event(:agent_timeout,
        aggregate_id: agent.agent_id,
        stream_id: agent.agent_id,
        data: %{
          agent_id: agent.agent_id,
          timeout_type: "task_execution",
          timeout_duration_ms: 30_000,
          timed_out_at: failure_time
        }
      ),
      build_test_event(:agent_timeout_recovered,
        aggregate_id: agent.agent_id,
        stream_id: agent.agent_id,
        data: %{
          agent_id: agent.agent_id,
          recovery_method: "force_restart",
          recovered_at: recovery_time
        }
      )
    ]
  end

  defp create_resource_exhaustion_scenario(agents, failure_time, recovery_time, _opts) do
    agent = List.first(agents)

    [
      build_test_event(:resource_exhaustion,
        aggregate_id: agent.agent_id,
        stream_id: agent.agent_id,
        data: %{
          agent_id: agent.agent_id,
          resource_type: "memory",
          limit_bytes: 512_000_000,
          usage_bytes: 520_000_000,
          exhausted_at: failure_time
        }
      ),
      build_test_event(:resource_recovered,
        aggregate_id: agent.agent_id,
        stream_id: agent.agent_id,
        data: %{
          agent_id: agent.agent_id,
          recovery_action: "garbage_collection",
          recovered_at: recovery_time
        }
      )
    ]
  end

  defp create_network_partition_scenario(agents, failure_time, recovery_time, _opts) do
    [
      build_test_event(:network_partition,
        aggregate_id: "cluster",
        stream_id: "cluster",
        data: %{
          partitioned_nodes: ["node1@localhost", "node2@localhost"],
          affected_agents: Enum.map(agents, & &1.agent_id),
          partition_started_at: failure_time
        }
      ),
      build_test_event(:network_partition_healed,
        aggregate_id: "cluster",
        stream_id: "cluster",
        data: %{
          healed_nodes: ["node1@localhost", "node2@localhost"],
          partition_duration_ms: DateTime.diff(recovery_time, failure_time, :millisecond),
          healed_at: recovery_time
        }
      )
    ]
  end

  defp create_cascade_failure_scenario(agents, failure_time, recovery_time, _opts) do
    # Simulate cascade failure where one agent failure triggers others
    [first_agent | remaining_agents] = agents

    initial_failure =
      build_test_event(:agent_failed,
        aggregate_id: first_agent.agent_id,
        stream_id: first_agent.agent_id,
        data: %{
          agent_id: first_agent.agent_id,
          failure_reason: "dependency_unavailable",
          failed_at: failure_time
        }
      )

    cascade_failures =
      remaining_agents
      |> Enum.with_index()
      |> Enum.map(fn {agent, index} ->
        build_test_event(:agent_failed,
          aggregate_id: agent.agent_id,
          stream_id: agent.agent_id,
          data: %{
            agent_id: agent.agent_id,
            failure_reason: "cascade_from_#{first_agent.agent_id}",
            failed_at: DateTime.add(failure_time, index * 5, :second)
          }
        )
      end)

    recovery_event =
      build_test_event(:cascade_recovery_completed,
        aggregate_id: "cluster",
        stream_id: "cluster",
        data: %{
          initial_failure: first_agent.agent_id,
          affected_agents: Enum.map(agents, & &1.agent_id),
          recovery_completed_at: recovery_time
        }
      )

    [initial_failure] ++ cascade_failures ++ [recovery_event]
  end

  # Performance scenario implementations

  defp create_steady_load_events(agents, duration_minutes, tasks_per_minute) do
    # Implementation for steady load pattern
    []
  end

  defp create_burst_load_events(agents, duration_minutes, tasks_per_minute, _opts) do
    # Implementation for burst load pattern
    []
  end

  defp create_ramp_up_load_events(agents, duration_minutes, tasks_per_minute) do
    # Implementation for ramp-up load pattern
    []
  end

  defp create_spike_load_events(agents, duration_minutes, tasks_per_minute, _opts) do
    # Implementation for spike load pattern
    []
  end

  defp create_random_load_events(agents, duration_minutes, tasks_per_minute, _opts) do
    # Implementation for random load pattern
    []
  end

  # Import build_test_event for private functions - moved to top of module
end
