defmodule Arbor.Security.MockEnforcer do
  @moduledoc """
  Mock implementation of SecurityEnforcer for unit testing.

  This mock provides a minimal implementation that satisfies the
  Arbor.Contracts.Security.Enforcer behaviour for unit testing purposes.
  It uses in-memory storage and simplified logic to enable fast,
  isolated unit tests.

  ## Test Capabilities

  The mock recognizes special patterns in capability metadata to simulate
  different validation outcomes:
  - `%{revoked: true}` - Capability is treated as revoked
  - `%{expired: true}` - Capability is treated as expired
  - Normal capabilities pass validation

  ## Usage

  This mock is automatically used when tests are tagged with `@moduletag security: :mock`.
  """

  @behaviour Arbor.Contracts.Security.Enforcer

  alias Arbor.Contracts.Core.Capability

  # In-memory store for mock state
  defstruct capabilities: %{}, audit_events: []

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  @impl true
  def authorize(%Capability{} = capability, resource_uri, operation, context, state) do
    with {:ok, :valid} <- validate_capability(capability, state),
         :ok <- check_capability_not_revoked(capability),
         :ok <- check_permissions(capability, resource_uri, operation),
         :ok <- verify_constraints(capability, context) do
      {:ok, :authorized}
    else
      {:error, reason} ->
        {:error, {:authorization_denied, reason}}
    end
  end

  @impl true
  def validate_capability(%Capability{} = capability, _state) do
    cond do
      # Check for revoked capability (test helper pattern)
      Map.get(capability.metadata, :revoked, false) ->
        {:error, :capability_revoked}

      # Check for expired capability
      not Capability.valid?(capability) ->
        {:error, :capability_expired}

      # Basic capability validation
      not valid_capability_format?(capability) ->
        {:error, :invalid_capability}

      true ->
        {:ok, :valid}
    end
  end

  @impl true
  def validate_capability(_invalid_capability, _state) do
    {:error, :invalid_capability}
  end

  @impl true
  def grant_capability(principal_id, resource_uri, constraints, granter_id, _state) do
    if valid_resource_uri?(resource_uri) do
      {:ok, capability} =
        Capability.new(
          resource_uri: resource_uri,
          principal_id: principal_id,
          constraints: constraints,
          metadata: %{granted_by: granter_id}
        )

      # Store capability in process dictionary for test simplicity
      capabilities = Process.get(:test_capabilities, %{})
      Process.put(:test_capabilities, Map.put(capabilities, capability.id, capability))

      {:ok, capability}
    else
      {:error, :invalid_resource_uri}
    end
  end

  @impl true
  def revoke_capability(capability_id, _reason, _revoker_id, cascade, _state) do
    capabilities = Process.get(:test_capabilities, %{})

    case Map.get(capabilities, capability_id) do
      nil ->
        {:error, :not_found}

      _capability ->
        # Remove capability from storage
        updated_capabilities = Map.delete(capabilities, capability_id)

        # If cascade is true, also revoke any delegated capabilities
        final_capabilities =
          if cascade do
            remove_delegated_capabilities(updated_capabilities, capability_id)
          else
            updated_capabilities
          end

        Process.put(:test_capabilities, final_capabilities)
        :ok
    end
  end

  @impl true
  def delegate_capability(parent_capability, delegate_to, constraints, _delegator_id, _state) do
    case Capability.delegate(parent_capability, delegate_to, constraints: constraints) do
      {:ok, delegated_capability} ->
        # Store delegated capability in process dictionary for test simplicity
        capabilities = Process.get(:test_capabilities, %{})

        Process.put(
          :test_capabilities,
          Map.put(capabilities, delegated_capability.id, delegated_capability)
        )

        {:ok, delegated_capability}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_capabilities(principal_id, filters, state) do
    capabilities =
      state.capabilities
      |> Map.values()
      |> Enum.filter(&(&1.principal_id == principal_id))
      |> apply_filters(filters)

    {:ok, capabilities}
  end

  @impl true
  def get_audit_trail(filters, state) do
    events =
      state.audit_events
      # Return in chronological order
      |> Enum.reverse()
      |> apply_audit_filters(filters)

    {:ok, events}
  end

  @impl true
  def check_policies(_operation, _resource_uri, _context, _state) do
    # Mock implementation - no policy violations in unit tests
    :ok
  end

  # Private helper functions

  defp check_permissions(%Capability{} = capability, resource_uri, operation) do
    if Capability.grants_access?(capability, resource_uri) do
      # Check if the capability's resource URI supports the requested operation
      # Extract operation from capability URI: arbor://fs/read/data -> read
      case extract_operation_from_uri(capability.resource_uri) do
        ^operation -> :ok
        _different_operation -> {:error, :operation_not_allowed}
      end
    else
      {:error, :insufficient_permissions}
    end
  end

  defp verify_constraints(%Capability{constraints: constraints}, context) do
    # Simple constraint checking for mock
    Enum.reduce_while(constraints, :ok, fn {key, value}, :ok ->
      case check_constraint(key, value, context) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp check_constraint(:max_uses, max_uses, context) do
    current_uses = Map.get(context, :current_uses, 0)

    if current_uses < max_uses do
      :ok
    else
      {:error, :constraint_violation}
    end
  end

  defp check_constraint(:request_size_limit, limit, context) do
    request_size = Map.get(context, :request_size, 0)

    if request_size <= limit do
      :ok
    else
      {:error, :constraint_violation}
    end
  end

  defp check_constraint(_key, _value, _context) do
    # Unknown constraints pass in mock
    :ok
  end

  defp valid_capability_format?(%Capability{
         id: id,
         principal_id: principal_id,
         resource_uri: uri
       })
       when is_binary(id) and is_binary(principal_id) and is_binary(uri) do
    String.starts_with?(id, "cap_") and
      String.starts_with?(principal_id, "agent_") and
      valid_resource_uri?(uri)
  end

  defp valid_capability_format?(_), do: false

  defp valid_resource_uri?(uri) when is_binary(uri) do
    String.match?(uri, ~r/^arbor:\/\/[a-z]+\/[a-z]+\/.+$/)
  end

  defp valid_resource_uri?(_), do: false

  defp extract_operation_from_uri(uri) do
    # Extract operation from URI like "arbor://fs/read/data" -> :read
    case String.split(uri, "/") do
      ["arbor:", "", _type, operation | _] -> String.to_atom(operation)
      _ -> :unknown
    end
  end

  defp filter_expired_capabilities(capabilities, include_expired?) do
    if include_expired? do
      capabilities
    else
      Enum.filter(capabilities, &Capability.valid?/1)
    end
  end

  defp filter_by_resource_type(capabilities, resource_type) do
    Enum.filter(capabilities, fn cap ->
      String.contains?(cap.resource_uri, "#{resource_type}/")
    end)
  end

  defp remove_delegated_capabilities(capabilities, parent_capability_id) do
    # Remove all capabilities that have the parent_capability_id as their parent
    capabilities
    |> Enum.reject(fn {_id, cap} ->
      Map.get(cap, :parent_capability_id) == parent_capability_id
    end)
    |> Enum.into(%{})
  end

  defp check_capability_not_revoked(%Capability{} = capability) do
    # Check if capability still exists in storage (not revoked)
    capabilities = Process.get(:test_capabilities, %{})

    if Map.has_key?(capabilities, capability.id) do
      :ok
    else
      # If it was stored originally but now missing, it was revoked
      # For test purposes, we'll assume any capability with parent_capability_id was stored
      if capability.parent_capability_id do
        {:error, :capability_revoked}
      else
        # Original capabilities that weren't stored are still valid
        :ok
      end
    end
  end

  defp apply_filters(capabilities, filters) do
    Enum.reduce(filters, capabilities, fn {key, value}, acc ->
      case key do
        :resource_type ->
          filter_by_resource_type(acc, value)

        :include_expired ->
          filter_expired_capabilities(acc, value)

        _ ->
          acc
      end
    end)
  end

  defp apply_audit_filters(events, filters) do
    Enum.reduce(filters, events, fn {key, value}, acc ->
      case key do
        :capability_id ->
          Enum.filter(acc, &(&1.capability_id == value))

        :principal_id ->
          Enum.filter(acc, &(&1.principal_id == value))

        :event_type ->
          Enum.filter(acc, &(&1.event_type == value))

        :limit ->
          Enum.take(acc, value)

        _ ->
          acc
      end
    end)
  end
end
