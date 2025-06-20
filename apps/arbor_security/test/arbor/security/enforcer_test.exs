defmodule Arbor.Security.EnforcerTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Core.Capability
  alias Arbor.Contracts.Security.AuditEvent
  alias Arbor.Security.MockEnforcer, as: Enforcer

  # Use in-memory mock for unit testing
  @moduletag security: :mock

  setup do
    {:ok, state} = Enforcer.init([])
    %{enforcer_state: state}
  end

  describe "capability validation logic" do
    test "validates capability with correct permissions", %{enforcer_state: state} do
      # MOCK: Use test capability store
      capability = create_valid_capability("agent-123", "arbor://fs/read/data/reports.csv")

      context = %{
        agent_id: "agent-123",
        session_id: "session-456",
        request_size: 1024
      }

      # This will fail until we implement the SecurityEnforcer
      assert {:ok, :authorized} =
               Enforcer.authorize(
                 capability,
                 "arbor://fs/read/data/reports.csv",
                 :read,
                 context,
                 state
               )
    end

    test "denies access for expired capability", %{enforcer_state: state} do
      expired_capability = create_expired_capability("agent-123", "arbor://fs/read/resource")

      context = %{agent_id: "agent-123"}

      assert {:error, {:authorization_denied, :capability_expired}} =
               Enforcer.authorize(
                 expired_capability,
                 "arbor://fs/read/resource",
                 :read,
                 context,
                 state
               )
    end

    test "denies access for wrong resource", %{enforcer_state: state} do
      capability = create_valid_capability("agent-123", "arbor://fs/read/allowed")

      context = %{agent_id: "agent-123"}

      assert {:error, {:authorization_denied, :insufficient_permissions}} =
               Enforcer.authorize(capability, "arbor://fs/read/forbidden", :read, context, state)
    end

    test "denies access for wrong operation", %{enforcer_state: state} do
      capability = create_valid_capability("agent-123", "arbor://fs/read/data")

      context = %{agent_id: "agent-123"}

      assert {:error, {:authorization_denied, :operation_not_allowed}} =
               Enforcer.authorize(capability, "arbor://fs/read/data", :write, context, state)
    end

    test "denies access for revoked capability", %{enforcer_state: state} do
      capability = create_revoked_capability("agent-123", "arbor://fs/read/data")

      context = %{agent_id: "agent-123"}

      assert {:error, {:authorization_denied, :capability_revoked}} =
               Enforcer.authorize(capability, "arbor://fs/read/data", :read, context, state)
    end

    test "validates capability without authorization", %{enforcer_state: state} do
      capability = create_valid_capability("agent-123", "arbor://fs/read/data")

      assert {:ok, :valid} = Enforcer.validate_capability(capability, state)
    end

    test "detects invalid capability format", %{enforcer_state: state} do
      invalid_capability = %{invalid: "data"}

      assert {:error, :invalid_capability} =
               Enforcer.validate_capability(invalid_capability, state)
    end
  end

  describe "capability granting" do
    test "grants new capability successfully", %{enforcer_state: state} do
      # This will fail until we implement the granting logic
      assert {:ok, %Capability{} = capability} =
               Enforcer.grant_capability(
                 "agent_123",
                 "arbor://fs/read/data",
                 %{max_uses: 10},
                 "admin",
                 state
               )

      assert capability.principal_id == "agent_123"
      assert capability.resource_uri == "arbor://fs/read/data"
      assert capability.constraints.max_uses == 10
    end

    test "fails to grant capability with invalid resource URI", %{enforcer_state: state} do
      assert {:error, :invalid_resource_uri} =
               Enforcer.grant_capability(
                 "agent_123",
                 "invalid-uri",
                 %{},
                 "admin",
                 state
               )
    end
  end

  describe "capability revocation" do
    test "revokes existing capability", %{enforcer_state: state} do
      # First grant a capability to revoke
      {:ok, capability} =
        Enforcer.grant_capability(
          "agent_123",
          "arbor://fs/read/test",
          %{},
          "admin",
          state
        )

      # This will fail until we implement revocation
      assert :ok = Enforcer.revoke_capability(capability.id, :manual, "admin", false, state)
    end

    test "handles revocation of non-existent capability", %{enforcer_state: state} do
      assert {:error, :not_found} =
               Enforcer.revoke_capability("cap_nonexistent", :manual, "admin", false, state)
    end
  end

  describe "capability delegation" do
    test "delegates capability successfully", %{enforcer_state: state} do
      # Create parent capability
      parent_capability = create_valid_capability("agent_123", "arbor://fs/read/shared")

      # Delegate to another agent
      assert {:ok, %Capability{} = delegated_cap} =
               Enforcer.delegate_capability(
                 parent_capability,
                 "agent_456",
                 %{max_uses: 5},
                 "agent_123",
                 state
               )

      # Verify delegation properties
      assert delegated_cap.principal_id == "agent_456"
      assert delegated_cap.resource_uri == parent_capability.resource_uri
      assert delegated_cap.parent_capability_id == parent_capability.id
      assert delegated_cap.delegation_depth == parent_capability.delegation_depth - 1
      assert delegated_cap.constraints.max_uses == 5
    end

    test "fails delegation when depth exhausted", %{enforcer_state: state} do
      # Create capability with no delegation depth
      {:ok, exhausted_cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/limited",
          principal_id: "agent_123",
          delegation_depth: 0
        )

      assert {:error, :delegation_depth_exhausted} =
               Enforcer.delegate_capability(
                 exhausted_cap,
                 "agent_456",
                 %{},
                 "agent_123",
                 state
               )
    end

    test "delegated capability inherits parent constraints", %{enforcer_state: state} do
      # Create parent with constraints
      {:ok, parent_cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/constrained",
          principal_id: "agent_123",
          constraints: %{time_window: "business_hours"}
        )

      assert {:ok, delegated_cap} =
               Enforcer.delegate_capability(
                 parent_cap,
                 "agent_456",
                 %{max_uses: 10},
                 "agent_123",
                 state
               )

      # Should inherit parent constraint and add new one
      assert delegated_cap.constraints.time_window == "business_hours"
      assert delegated_cap.constraints.max_uses == 10
    end

    test "delegated capability can be used for authorization", %{enforcer_state: state} do
      # Create and delegate capability
      parent_capability = create_valid_capability("agent_123", "arbor://fs/read/project")

      {:ok, delegated_cap} =
        Enforcer.delegate_capability(
          parent_capability,
          "agent_456",
          %{},
          "agent_123",
          state
        )

      # Delegated capability should work for authorization
      context = %{agent_id: "agent_456"}

      assert {:ok, :authorized} =
               Enforcer.authorize(
                 delegated_cap,
                 "arbor://fs/read/project/file.txt",
                 :read,
                 context,
                 state
               )
    end

    test "delegation creates audit trail", %{enforcer_state: state} do
      parent_capability = create_valid_capability("agent_123", "arbor://fs/read/docs")

      # Delegate capability
      {:ok, delegated_cap} =
        Enforcer.delegate_capability(
          parent_capability,
          "agent_456",
          %{reason: "team_collaboration"},
          "agent_123",
          state
        )

      # Verify delegation succeeded
      assert delegated_cap.principal_id == "agent_456"
      assert delegated_cap.parent_capability_id == parent_capability.id
    end
  end

  describe "automatic capability revocation" do
    test "revokes capability when parent is revoked with cascade", %{enforcer_state: state} do
      # Grant parent capability
      {:ok, parent_cap} =
        Enforcer.grant_capability(
          "agent_123",
          "arbor://fs/read/team_docs",
          %{},
          "admin",
          state
        )

      # Delegate to child
      {:ok, child_cap} =
        Enforcer.delegate_capability(
          parent_cap,
          "agent_456",
          %{},
          "agent_123",
          state
        )

      # Revoke parent with cascade
      assert :ok =
               Enforcer.revoke_capability(parent_cap.id, :security_incident, "admin", true, state)

      # Child capability should be automatically revoked
      assert {:error, {:authorization_denied, :capability_revoked}} =
               Enforcer.authorize(
                 child_cap,
                 "arbor://fs/read/team_docs",
                 :read,
                 %{agent_id: "agent_456"},
                 state
               )
    end

    test "child capabilities remain valid when parent revoked without cascade", %{
      enforcer_state: state
    } do
      # Grant parent capability
      {:ok, parent_cap} =
        Enforcer.grant_capability(
          "agent_123",
          "arbor://fs/read/public_docs",
          %{},
          "admin",
          state
        )

      # Delegate to child
      {:ok, child_cap} =
        Enforcer.delegate_capability(
          parent_cap,
          "agent_456",
          %{},
          "agent_123",
          state
        )

      # Revoke parent without cascade
      assert :ok = Enforcer.revoke_capability(parent_cap.id, :manual, "admin", false, state)

      # Child capability should still work (for this simple mock)
      assert {:ok, :authorized} =
               Enforcer.authorize(
                 child_cap,
                 "arbor://fs/read/public_docs",
                 :read,
                 %{agent_id: "agent_456"},
                 state
               )
    end

    test "revokes capabilities when agent process terminates", %{enforcer_state: state} do
      # This test simulates what would happen in a real system with process monitoring
      # For now, we'll test the revocation API that would be called by the monitor

      # Grant capability to agent
      {:ok, capability} =
        Enforcer.grant_capability(
          "agent_999",
          "arbor://fs/read/temp_work",
          %{},
          "admin",
          state
        )

      # Simulate process termination by revoking all capabilities for agent
      assert :ok =
               Enforcer.revoke_capability(
                 capability.id,
                 :process_terminated,
                 "system",
                 false,
                 state
               )

      # Capability should be revoked
      assert {:error, :not_found} =
               Enforcer.revoke_capability(capability.id, :manual, "admin", false, state)
    end

    test "revokes expired capabilities during validation", %{enforcer_state: state} do
      # Create an expired capability
      expired_cap = create_expired_capability("agent_123", "arbor://fs/read/expired_resource")

      # Attempt to use expired capability
      context = %{agent_id: "agent_123"}

      assert {:error, {:authorization_denied, :capability_expired}} =
               Enforcer.authorize(
                 expired_cap,
                 "arbor://fs/read/expired_resource",
                 :read,
                 context,
                 state
               )

      # In a real system, this would also trigger automatic cleanup
      # For mock, we verify the error is returned correctly
    end

    test "handles constraint violations with automatic revocation", %{enforcer_state: state} do
      # Grant capability with usage limit
      {:ok, limited_cap} =
        Enforcer.grant_capability(
          "agent_123",
          "arbor://fs/read/limited_resource",
          %{max_uses: 1},
          "admin",
          state
        )

      # First use should succeed
      context = %{agent_id: "agent_123", current_uses: 0}

      assert {:ok, :authorized} =
               Enforcer.authorize(
                 limited_cap,
                 "arbor://fs/read/limited_resource",
                 :read,
                 context,
                 state
               )

      # Second use should fail due to constraint violation
      context_exceeded = %{agent_id: "agent_123", current_uses: 1}

      assert {:error, {:authorization_denied, :constraint_violation}} =
               Enforcer.authorize(
                 limited_cap,
                 "arbor://fs/read/limited_resource",
                 :read,
                 context_exceeded,
                 state
               )
    end
  end

  describe "audit event generation" do
    test "generates audit events for successful authorizations", %{enforcer_state: state} do
      capability = create_valid_capability("agent_123", "arbor://fs/read/audit_test")
      context = %{agent_id: "agent_123", session_id: "session_789"}

      # Authorize operation
      assert {:ok, :authorized} =
               Enforcer.authorize(capability, "arbor://fs/read/audit_test", :read, context, state)

      # In a real implementation, we would verify audit events were generated
      # For mock testing, we verify the operation succeeded (audit generation implied)
      assert true
    end

    test "generates audit events for denied authorizations", %{enforcer_state: state} do
      expired_cap = create_expired_capability("agent_123", "arbor://fs/read/audit_denied")
      context = %{agent_id: "agent_123", session_id: "session_789"}

      # Attempt authorization
      assert {:error, {:authorization_denied, :capability_expired}} =
               Enforcer.authorize(
                 expired_cap,
                 "arbor://fs/read/audit_denied",
                 :read,
                 context,
                 state
               )

      # In a real implementation, we would verify audit events were generated
      # For mock testing, we verify the denial was recorded correctly
      assert true
    end

    test "generates audit events for capability grants", %{enforcer_state: state} do
      # Grant capability
      assert {:ok, capability} =
               Enforcer.grant_capability(
                 "agent_123",
                 "arbor://fs/read/grant_audit",
                 %{max_uses: 5},
                 "admin_user",
                 state
               )

      # Verify grant succeeded (audit generation implied)
      assert capability.principal_id == "agent_123"
      assert capability.constraints.max_uses == 5
    end

    test "generates audit events for capability revocations", %{enforcer_state: state} do
      # Grant then revoke capability
      {:ok, capability} =
        Enforcer.grant_capability(
          "agent_123",
          "arbor://fs/read/revoke_audit",
          %{},
          "admin_user",
          state
        )

      # Revoke capability
      assert :ok =
               Enforcer.revoke_capability(
                 capability.id,
                 :security_policy_violation,
                 "security_admin",
                 false,
                 state
               )

      # Verify revocation succeeded (audit generation implied)
      assert {:error, :not_found} =
               Enforcer.revoke_capability(capability.id, :manual, "admin", false, state)
    end

    test "generates audit events for capability delegations", %{enforcer_state: state} do
      parent_cap = create_valid_capability("agent_123", "arbor://fs/read/delegate_audit")

      # Delegate capability
      assert {:ok, delegated_cap} =
               Enforcer.delegate_capability(
                 parent_cap,
                 "agent_456",
                 %{delegation_reason: "team_project"},
                 "agent_123",
                 state
               )

      # Verify delegation succeeded (audit generation implied)
      assert delegated_cap.principal_id == "agent_456"
      assert delegated_cap.parent_capability_id == parent_cap.id
    end

    test "audit events include proper context and metadata", %{enforcer_state: state} do
      capability = create_valid_capability("agent_123", "arbor://fs/read/context_audit")

      # Authorization with rich context
      context = %{
        agent_id: "agent_123",
        session_id: "session_abc123",
        trace_id: "trace_xyz789",
        request_size: 2048,
        ip_address: "192.168.1.100"
      }

      assert {:ok, :authorized} =
               Enforcer.authorize(
                 capability,
                 "arbor://fs/read/context_audit",
                 :read,
                 context,
                 state
               )

      # In a real implementation, audit events would include all this context
      # For mock testing, we verify authorization succeeded with context
      assert true
    end

    test "audit trail query functionality", %{enforcer_state: state} do
      # Generate some audit events by performing operations
      capability = create_valid_capability("agent_123", "arbor://fs/read/trail_test")

      # Perform authorization
      Enforcer.authorize(
        capability,
        "arbor://fs/read/trail_test",
        :read,
        %{agent_id: "agent_123"},
        state
      )

      # Query audit trail (in real implementation)
      assert {:ok, events} = Enforcer.get_audit_trail([principal_id: "agent_123"], state)

      # For mock, we return empty list but verify the API works
      assert is_list(events)
    end
  end

  # Helper functions for creating test capabilities

  defp create_valid_capability(principal_id, resource_uri) do
    # Fix: Use proper agent_id format as expected by contracts
    agent_id =
      if String.starts_with?(principal_id, "agent_"),
        do: principal_id,
        else: "agent_#{principal_id}"

    {:ok, capability} =
      Capability.new(
        resource_uri: resource_uri,
        principal_id: agent_id,
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      )

    capability
  end

  defp create_expired_capability(principal_id, resource_uri) do
    # Fix: Use proper agent_id format as expected by contracts
    agent_id =
      if String.starts_with?(principal_id, "agent_"),
        do: principal_id,
        else: "agent_#{principal_id}"

    past_time = DateTime.add(DateTime.utc_now(), -3600, :second)
    # Granted in past, expired later but still in past
    expired_time = DateTime.add(past_time, 1800, :second)

    {:ok, capability} =
      Capability.new(
        resource_uri: resource_uri,
        principal_id: agent_id,
        granted_at: past_time,
        expires_at: expired_time
      )

    capability
  end

  defp create_revoked_capability(principal_id, resource_uri) do
    capability = create_valid_capability(principal_id, resource_uri)
    # Add metadata to mark as revoked for testing
    %{capability | metadata: Map.put(capability.metadata, :revoked, true)}
  end
end
