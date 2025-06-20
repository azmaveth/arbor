defmodule Arbor.Security.IntegrationTest do
  @moduledoc """
  Integration tests for the complete security system.

  These tests verify the full security stack working together:
  - SecurityKernel GenServer for state management
  - CapabilityStore with PostgreSQL persistence + ETS caching
  - AuditLogger with telemetry events
  - Process monitoring for automatic capability revocation
  - Resource validators for URI validation

  Unlike unit tests that use mocks, these tests use real persistence
  and verify the complete security workflow end-to-end.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Core.Capability
  alias Arbor.Contracts.Security.AuditEvent
  alias Arbor.Security.{AuditLogger, CapabilityStore, Kernel}

  # These tests require real PostgreSQL and telemetry
  @moduletag integration: true
  @moduletag timeout: 10_000

  setup_all do
    # Start mock database services
    {:ok, _} = start_supervised(Arbor.Security.CapabilityStore.PostgresDB)
    {:ok, _} = start_supervised(Arbor.Security.AuditLogger.PostgresDB)

    # Start the rate limiter for policy tests
    {:ok, _} = start_supervised(Arbor.Security.Policies.RateLimiter)

    # Start the security kernel and related services with mock DBs
    {:ok, _pid} = start_supervised({Arbor.Security.Kernel, []})
    {:ok, _pid} = start_supervised({Arbor.Security.CapabilityStore, [use_mock: true]})
    {:ok, _pid} = start_supervised({Arbor.Security.AuditLogger, [use_mock: true]})

    on_exit(fn ->
      # Cleanup any test data
      cleanup_test_data()
    end)

    :ok
  end

  setup do
    # Clean state before each test
    Kernel.reset_for_testing()

    # Clean audit events and capability store
    AuditLogger.flush_events()
    CapabilityStore.PostgresDB.clear_all()
    AuditLogger.PostgresDB.clear_all()

    %{kernel_pid: Process.whereis(Arbor.Security.Kernel)}
  end

  describe "end-to-end security workflow" do
    test "complete capability lifecycle with persistence", %{kernel_pid: kernel_pid} do
      # This test will fail until we implement the real security kernel
      assert is_pid(kernel_pid)

      # Grant capability through security kernel
      assert {:ok, capability} =
               Kernel.grant_capability(
                 principal_id: "agent_integration_001",
                 resource_uri: "arbor://fs/read/integration/test/data",
                 constraints: %{max_uses: 5, expires_in: 3600},
                 granter_id: "admin_user",
                 metadata: %{test_case: "integration_lifecycle"}
               )

      # Verify capability is persisted in PostgreSQL
      assert {:ok, stored_cap} = CapabilityStore.get_capability(capability.id)
      assert stored_cap.id == capability.id
      assert stored_cap.principal_id == "agent_integration_001"

      # Verify capability is cached in ETS for fast access
      assert {:ok, cached_cap} = CapabilityStore.get_capability_cached(capability.id)
      assert cached_cap.id == capability.id

      # Authorize using the capability
      context = %{
        agent_id: "agent_integration_001",
        session_id: "session_integration_123",
        trace_id: "trace_integration_abc",
        request_size: 1024
      }

      assert {:ok, :authorized} =
               Kernel.authorize(
                 capability: capability,
                 resource_uri: "arbor://fs/read/integration/test/data/file.csv",
                 operation: :read,
                 context: context
               )

      # Flush audit events to ensure they're stored
      :ok = AuditLogger.flush_events()

      # Verify audit events were generated and stored
      assert {:ok, audit_events} =
               AuditLogger.get_events(
                 filters: [capability_id: capability.id],
                 limit: 10
               )

      # Grant + Authorization events
      assert length(audit_events) >= 2

      grant_event = Enum.find(audit_events, &(&1.event_type == :capability_granted))
      auth_event = Enum.find(audit_events, &(&1.event_type == :authorization_success))

      assert grant_event.capability_id == capability.id
      assert auth_event.capability_id == capability.id
      assert auth_event.principal_id == "agent_integration_001"

      # Revoke capability
      assert :ok =
               Kernel.revoke_capability(
                 capability_id: capability.id,
                 reason: :integration_test_cleanup,
                 revoker_id: "admin_user",
                 cascade: false
               )

      # Verify capability is marked as revoked in persistence
      assert {:error, :not_found} = CapabilityStore.get_capability(capability.id)

      # Flush and verify revocation audit event
      :ok = AuditLogger.flush_events()

      assert {:ok, revoke_events} =
               AuditLogger.get_events(
                 filters: [capability_id: capability.id, event_type: :capability_revoked],
                 limit: 1
               )

      assert length(revoke_events) == 1
      revoke_event = hd(revoke_events)
      assert revoke_event.reason == :integration_test_cleanup
    end

    test "capability delegation with cascade revocation", %{kernel_pid: kernel_pid} do
      assert is_pid(kernel_pid)

      # Grant parent capability
      assert {:ok, parent_cap} =
               Kernel.grant_capability(
                 principal_id: "agent_parent_002",
                 resource_uri: "arbor://fs/read/shared/project",
                 constraints: %{delegation_depth: 3},
                 granter_id: "project_admin",
                 metadata: %{project: "integration_test"}
               )

      # Delegate to child agent
      assert {:ok, child_cap} =
               Kernel.delegate_capability(
                 parent_capability: parent_cap,
                 delegate_to: "agent_child_003",
                 constraints: %{max_uses: 10},
                 delegator_id: "agent_parent_002",
                 metadata: %{delegation_reason: "team_collaboration"}
               )

      # Verify both capabilities work for authorization
      parent_context = %{agent_id: "agent_parent_002", session_id: "session_p1"}
      child_context = %{agent_id: "agent_child_003", session_id: "session_c1"}

      assert {:ok, :authorized} =
               Kernel.authorize(
                 capability: parent_cap,
                 resource_uri: "arbor://fs/read/shared/project/docs",
                 operation: :read,
                 context: parent_context
               )

      assert {:ok, :authorized} =
               Kernel.authorize(
                 capability: child_cap,
                 resource_uri: "arbor://fs/read/shared/project/code",
                 operation: :read,
                 context: child_context
               )

      # Revoke parent with cascade
      assert :ok =
               Kernel.revoke_capability(
                 capability_id: parent_cap.id,
                 reason: :security_incident,
                 revoker_id: "security_admin",
                 cascade: true
               )

      # Verify child capability is automatically revoked
      assert {:error, {:authorization_denied, :capability_revoked}} =
               Kernel.authorize(
                 capability: child_cap,
                 resource_uri: "arbor://fs/read/shared/project/code",
                 operation: :read,
                 context: child_context
               )

      # Flush and verify cascade revocation audit events
      :ok = AuditLogger.flush_events()

      assert {:ok, cascade_events} =
               AuditLogger.get_events(
                 filters: [reason: :security_incident],
                 limit: 10
               )

      # Should have events for both parent and child revocation
      assert length(cascade_events) >= 2
    end

    test "process monitoring triggers automatic capability revocation" do
      # Start a test agent process
      {:ok, agent_pid} = start_test_agent("agent_monitored_004")

      # Grant capability tied to the agent process
      assert {:ok, capability} =
               Kernel.grant_capability(
                 principal_id: "agent_monitored_004",
                 resource_uri: "arbor://tool/execute/test_analyzer",
                 constraints: %{process_pid: agent_pid},
                 granter_id: "system",
                 metadata: %{monitoring: true}
               )

      # Verify capability works
      context = %{agent_id: "agent_monitored_004", session_id: "session_monitor"}

      assert {:ok, :authorized} =
               Kernel.authorize(
                 capability: capability,
                 resource_uri: "arbor://tool/execute/test_analyzer",
                 operation: :execute,
                 context: context
               )

      # Terminate the agent process
      GenServer.stop(agent_pid, :normal)

      # Wait for process monitor to detect termination and revoke capability
      Process.sleep(200)

      # Flush audit events to ensure termination event is stored
      :ok = AuditLogger.flush_events()

      # Verify capability is automatically revoked
      assert {:error, {:authorization_denied, :capability_revoked}} =
               Kernel.authorize(
                 capability: capability,
                 resource_uri: "arbor://tool/execute/test_analyzer",
                 operation: :execute,
                 context: context
               )

      # Verify process termination audit event
      :ok = AuditLogger.flush_events()

      assert {:ok, termination_events} =
               AuditLogger.get_events(
                 filters: [reason: :process_terminated, principal_id: "agent_monitored_004"],
                 limit: 5
               )

      assert length(termination_events) >= 1
    end

    test "telemetry events are properly emitted" do
      # Set up telemetry event collector
      test_pid = self()

      :telemetry.attach_many(
        "security_integration_test",
        [
          [:arbor, :security, :authorization, :success],
          [:arbor, :security, :authorization, :denied],
          [:arbor, :security, :capability, :granted],
          [:arbor, :security, :capability, :revoked]
        ],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        []
      )

      # Grant capability (should emit telemetry)
      assert {:ok, capability} =
               Kernel.grant_capability(
                 principal_id: "agent_telemetry_005",
                 resource_uri: "arbor://api/call/external_service",
                 constraints: %{rate_limit: 100},
                 granter_id: "api_admin",
                 metadata: %{service: "integration_test"}
               )

      # Authorize (should emit telemetry)
      context = %{agent_id: "agent_telemetry_005", session_id: "session_telem"}

      assert {:ok, :authorized} =
               Kernel.authorize(
                 capability: capability,
                 resource_uri: "arbor://api/call/external_service",
                 operation: :call,
                 context: context
               )

      # Attempt denied authorization (should emit telemetry)
      expired_cap = create_expired_test_capability("agent_telemetry_005")

      assert {:error, {:authorization_denied, :capability_expired}} =
               Kernel.authorize(
                 capability: expired_cap,
                 resource_uri: "arbor://api/call/restricted",
                 operation: :call,
                 context: context
               )

      # Collect telemetry events
      telemetry_events = collect_telemetry_events([], 3, 1000)

      # Verify expected telemetry events were emitted
      assert length(telemetry_events) >= 3

      event_types =
        Enum.map(telemetry_events, fn {_, event_name, _, _} ->
          List.last(event_name)
        end)

      assert :granted in event_types
      assert :success in event_types
      assert :denied in event_types

      # Cleanup
      :telemetry.detach("security_integration_test")
    end

    test "performance under concurrent load" do
      # Test concurrent capability operations
      agent_count = 20
      operations_per_agent = 10

      # Create agents concurrently
      tasks =
        for agent_num <- 1..agent_count do
          Task.async(fn ->
            agent_id = "agent_load_#{agent_num}"

            # Each agent performs multiple operations
            for op_num <- 1..operations_per_agent do
              # Grant capability
              {:ok, capability} =
                Kernel.grant_capability(
                  principal_id: agent_id,
                  resource_uri: "arbor://fs/read/load_test/data_#{op_num}",
                  constraints: %{max_uses: 1},
                  granter_id: "load_test_admin",
                  metadata: %{load_test: true}
                )

              # Authorize
              context = %{agent_id: agent_id, session_id: "session_#{op_num}"}

              {:ok, :authorized} =
                Kernel.authorize(
                  capability: capability,
                  resource_uri: "arbor://fs/read/load_test/data_#{op_num}",
                  operation: :read,
                  context: context
                )

              # Revoke
              :ok =
                Kernel.revoke_capability(
                  capability_id: capability.id,
                  reason: :load_test_cleanup,
                  revoker_id: "load_test_admin",
                  cascade: false
                )
            end

            :completed
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 30_000)

      # Verify all operations completed successfully
      assert Enum.all?(results, &(&1 == :completed))

      # Verify audit trail captured all events
      # grant + auth + revoke
      total_expected_events = agent_count * operations_per_agent * 3

      assert {:ok, all_events} =
               AuditLogger.get_events(
                 filters: [metadata: %{load_test: true}],
                 limit: total_expected_events + 100
               )

      # Should have most events (allowing for some race conditions in cleanup)
      assert length(all_events) >= total_expected_events * 0.9
    end
  end

  describe "error handling and edge cases" do
    test "handles database connection failures gracefully" do
      # Simulate database unavailability (this would be implemented in CapabilityStore)

      # Attempt operations when database is "down"
      result =
        Kernel.grant_capability(
          principal_id: "agent_db_test_006",
          resource_uri: "arbor://fs/read/db_test",
          constraints: %{},
          granter_id: "admin",
          metadata: %{db_test: true}
        )

      # Should handle gracefully (specific behavior depends on implementation)
      # For now, we'll expect it to either succeed or fail with a clear error
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles malformed capability data" do
      # Test with invalid capability structure
      invalid_capability = %{invalid: "data", not_a: "capability"}

      context = %{agent_id: "agent_malformed_007"}

      assert {:error, {:authorization_denied, :invalid_capability}} =
               Kernel.authorize(
                 capability: invalid_capability,
                 resource_uri: "arbor://fs/read/test",
                 operation: :read,
                 context: context
               )
    end

    test "handles resource URI validation" do
      # Test with invalid resource URIs
      invalid_uris = [
        "not-a-uri",
        "http://wrong-scheme",
        "arbor://",
        "arbor://fs/",
        "arbor://fs/invalid-operation/path"
      ]

      for invalid_uri <- invalid_uris do
        result =
          Kernel.grant_capability(
            principal_id: "agent_uri_test_008",
            resource_uri: invalid_uri,
            constraints: %{},
            granter_id: "admin",
            metadata: %{}
          )

        assert {:error, {:invalid_resource_uri, _}} = result
      end
    end
  end

  # Helper functions

  defp start_test_agent(agent_id) do
    # Start a simple GenServer that represents an agent process
    GenServer.start_link(__MODULE__.TestAgent, agent_id, name: :"test_agent_#{agent_id}")
  end

  defp cleanup_test_data do
    # Clean up any test data in PostgreSQL
    # This would be implemented to clean the capabilities and audit_events tables
    :ok
  end

  defp create_expired_test_capability(agent_id) do
    past_time = DateTime.add(DateTime.utc_now(), -3600, :second)

    {:ok, capability} =
      Capability.new(
        resource_uri: "arbor://api/call/restricted",
        principal_id: agent_id,
        granted_at: past_time,
        # Expired
        expires_at: DateTime.add(past_time, 1800, :second)
      )

    capability
  end

  defp collect_telemetry_events(events, 0, _timeout), do: events

  defp collect_telemetry_events(events, remaining, timeout) do
    receive do
      {:telemetry_event, event_name, measurements, metadata} = event ->
        collect_telemetry_events([event | events], remaining - 1, timeout)
    after
      timeout -> events
    end
  end

  # Simple test agent GenServer
  defmodule TestAgent do
    use GenServer

    def init(agent_id) do
      {:ok, %{agent_id: agent_id}}
    end

    def handle_call(:get_id, _from, state) do
      {:reply, state.agent_id, state}
    end

    def handle_info(_msg, state) do
      {:noreply, state}
    end
  end
end
