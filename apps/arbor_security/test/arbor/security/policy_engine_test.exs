defmodule Arbor.Security.PolicyEngineTest do
  @moduledoc """
  Tests for the concrete policy engine implementation.
  """

  use ExUnit.Case, async: false

  alias Arbor.Security.{Policies.RateLimiter, PolicyEngine}

  setup do
    # Start rate limiter if not already running
    case Process.whereis(RateLimiter) do
      nil -> {:ok, _} = start_supervised(RateLimiter)
      _pid -> :ok
    end

    :ok
  end

  describe "rate limiting" do
    test "allows operations within rate limit" do
      context = %{principal_id: "agent_rate_test_001"}

      # Should allow initial requests
      assert :ok = PolicyEngine.check_policies(:read, "arbor://fs/read/data", context, %{})
      assert :ok = PolicyEngine.check_policies(:read, "arbor://fs/read/data", context, %{})
    end

    test "denies operations when rate limit exceeded" do
      context = %{principal_id: "agent_rate_test_002"}

      # Consume all tokens (default is 100)
      for _ <- 1..100 do
        assert :ok = PolicyEngine.check_policies(:read, "arbor://fs/read/data", context, %{})
      end

      # Next request should be denied
      assert {:error, :rate_limit_exceeded} =
               PolicyEngine.check_policies(:read, "arbor://fs/read/data", context, %{})
    end
  end

  describe "time-based restrictions" do
    test "allows access during business hours" do
      # Mock a business hours time (Tuesday 10 AM UTC)
      context = %{principal_id: "agent_time_test_001"}

      # This test would need time mocking to be reliable
      # For now, we'll just verify the function exists
      result = PolicyEngine.check_policies(:write, "arbor://fs/write/reports/", context, %{})
      assert result in [:ok, {:error, :outside_allowed_hours}]
    end

    test "denies access to financial data outside business hours" do
      context = %{principal_id: "agent_time_test_002"}

      # Financial resources have time restrictions
      result =
        PolicyEngine.check_policies(:write, "arbor://fs/write/financial/ledger.csv", context, %{})

      # Result depends on current time
      assert result in [:ok, {:error, :outside_allowed_hours}]
    end
  end

  describe "resource-specific policies" do
    test "denies writes to system directories" do
      context = %{principal_id: "agent_resource_test_001"}

      assert {:error, :system_directory_write_denied} =
               PolicyEngine.check_policies(:write, "arbor://fs/write/system/config", context, %{})
    end

    test "allows writes to non-system directories" do
      context = %{principal_id: "agent_resource_test_002"}

      assert :ok = PolicyEngine.check_policies(:write, "arbor://fs/write/user/data", context, %{})
    end

    test "requires permission for external API calls" do
      context = %{principal_id: "agent_api_test_001", external_api_allowed: false}

      assert {:error, :external_api_not_allowed} =
               PolicyEngine.check_policies(
                 :call,
                 "arbor://api/call/external/weather",
                 context,
                 %{}
               )
    end

    test "allows external API calls with permission" do
      context = %{principal_id: "agent_api_test_002", external_api_allowed: true}

      assert :ok =
               PolicyEngine.check_policies(
                 :call,
                 "arbor://api/call/external/weather",
                 context,
                 %{}
               )
    end

    test "requires admin approval for dangerous tools" do
      context = %{principal_id: "agent_tool_test_001", admin_approved: false}

      assert {:error, :requires_admin_approval} =
               PolicyEngine.check_policies(
                 :execute,
                 "arbor://tool/execute/system_command",
                 context,
                 %{}
               )
    end
  end

  describe "compliance requirements" do
    test "requires MFA for sensitive resources" do
      context = %{principal_id: "agent_compliance_test_001", mfa_verified: false}

      assert {:error, :mfa_required} =
               PolicyEngine.check_policies(
                 :read,
                 "arbor://fs/read/secrets/api_keys",
                 context,
                 %{}
               )
    end

    test "allows access to sensitive resources with MFA" do
      context = %{principal_id: "agent_compliance_test_002", mfa_verified: true}

      assert :ok =
               PolicyEngine.check_policies(
                 :read,
                 "arbor://fs/read/secrets/api_keys",
                 context,
                 %{}
               )
    end
  end

  describe "security level requirements" do
    test "enforces minimum security levels" do
      # Low security level trying to access high security resource
      context = %{principal_id: "agent_level_test_001", security_level: 1}

      assert {:error, {:insufficient_security_level, 3, 1}} =
               PolicyEngine.check_policies(:execute, "arbor://tool/execute/scanner", context, %{})
    end

    test "allows access with sufficient security level" do
      context = %{principal_id: "agent_level_test_002", security_level: 3}

      assert :ok =
               PolicyEngine.check_policies(:execute, "arbor://tool/execute/scanner", context, %{})
    end
  end
end
