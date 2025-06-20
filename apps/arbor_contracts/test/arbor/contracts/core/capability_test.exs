defmodule Arbor.Contracts.Core.CapabilityTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Core.Capability

  describe "new/1" do
    test "creates a valid capability with required fields" do
      attrs = [
        resource_uri: "arbor://fs/read/home/user/docs",
        principal_id: "agent_123"
      ]

      assert {:ok, %Capability{} = cap} = Capability.new(attrs)
      assert cap.resource_uri == "arbor://fs/read/home/user/docs"
      assert cap.principal_id == "agent_123"
      assert cap.delegation_depth == 3
      assert cap.constraints == %{}
      assert cap.metadata == %{}
      assert String.starts_with?(cap.id, "cap_")
      assert cap.granted_at != nil
    end

    test "creates capability with all optional fields" do
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      attrs = [
        id: "cap_custom_id",
        resource_uri: "arbor://api/call/external",
        principal_id: "agent_456",
        expires_at: expires_at,
        parent_capability_id: "cap_parent",
        delegation_depth: 1,
        constraints: %{max_calls: 100},
        metadata: %{purpose: "testing"}
      ]

      assert {:ok, %Capability{} = cap} = Capability.new(attrs)
      assert cap.id == "cap_custom_id"
      assert cap.expires_at == expires_at
      assert cap.parent_capability_id == "cap_parent"
      assert cap.delegation_depth == 1
      assert cap.constraints == %{max_calls: 100}
      assert cap.metadata == %{purpose: "testing"}
    end

    test "fails with invalid resource URI" do
      attrs = [
        resource_uri: "invalid://uri",
        principal_id: "agent_123"
      ]

      assert {:error, {:invalid_resource_uri, "invalid://uri"}} = Capability.new(attrs)
    end

    test "fails with invalid principal ID" do
      attrs = [
        resource_uri: "arbor://fs/read/docs",
        principal_id: "invalid_id"
      ]

      assert {:error, {:invalid_principal_id, "invalid_id"}} = Capability.new(attrs)
    end

    test "fails when expires before granted" do
      now = DateTime.utc_now()
      past = DateTime.add(now, -3600, :second)

      attrs = [
        resource_uri: "arbor://fs/read/docs",
        principal_id: "agent_123",
        granted_at: now,
        expires_at: past
      ]

      assert {:error, {:expires_before_granted, ^past, ^now}} = Capability.new(attrs)
    end
  end

  describe "valid?/1" do
    test "returns true for non-expired capability" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_123"
        )

      assert Capability.valid?(cap)
    end

    test "returns false for expired capability" do
      # Create a capability that will expire in 10ms
      future = DateTime.add(DateTime.utc_now(), 10, :millisecond)

      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_123",
          expires_at: future
        )

      # Wait for it to expire
      Process.sleep(15)

      refute Capability.valid?(cap)
    end

    test "returns true for capability with delegation depth" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_123",
          delegation_depth: 5
        )

      assert Capability.valid?(cap)
    end
  end

  describe "grants_access?/2" do
    test "grants access to exact resource match" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/home/user/docs",
          principal_id: "agent_123"
        )

      assert Capability.grants_access?(cap, "arbor://fs/read/home/user/docs")
    end

    test "grants access to child resources" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/home/user",
          principal_id: "agent_123"
        )

      assert Capability.grants_access?(cap, "arbor://fs/read/home/user/docs")
      assert Capability.grants_access?(cap, "arbor://fs/read/home/user/photos/vacation.jpg")
    end

    test "denies access to parent resources" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/home/user/docs",
          principal_id: "agent_123"
        )

      refute Capability.grants_access?(cap, "arbor://fs/read/home")
      refute Capability.grants_access?(cap, "arbor://fs/read/home/user")
    end

    test "denies access to sibling resources" do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/read/home/user/docs",
          principal_id: "agent_123"
        )

      refute Capability.grants_access?(cap, "arbor://fs/read/home/user/photos")
      refute Capability.grants_access?(cap, "arbor://fs/write/home/user/docs")
    end
  end

  describe "delegate/3" do
    setup do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/read/home/user",
          principal_id: "agent_parent",
          delegation_depth: 3,
          constraints: %{max_files: 100}
        )

      {:ok, parent: parent}
    end

    test "creates delegated capability with reduced depth", %{parent: parent} do
      {:ok, delegated} = Capability.delegate(parent, "agent_child", [])

      assert delegated.resource_uri == parent.resource_uri
      assert delegated.principal_id == "agent_child"
      assert delegated.parent_capability_id == parent.id
      assert delegated.delegation_depth == 2
      assert delegated.constraints == parent.constraints
    end

    test "merges additional constraints", %{parent: parent} do
      {:ok, delegated} =
        Capability.delegate(parent, "agent_child", constraints: %{max_size: 1024})

      assert delegated.constraints == %{max_files: 100, max_size: 1024}
    end

    test "uses shorter expiration time", %{parent: parent} do
      parent_expires = DateTime.add(DateTime.utc_now(), 7200, :second)
      delegate_expires = DateTime.add(DateTime.utc_now(), 3600, :second)

      parent = %{parent | expires_at: parent_expires}

      {:ok, delegated} = Capability.delegate(parent, "agent_child", expires_at: delegate_expires)

      assert delegated.expires_at == delegate_expires
    end

    test "fails when delegation depth exhausted" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/read/docs",
          principal_id: "agent_123",
          delegation_depth: 0
        )

      assert {:error, :delegation_depth_exhausted} =
               Capability.delegate(parent, "agent_child", [])
    end
  end
end
