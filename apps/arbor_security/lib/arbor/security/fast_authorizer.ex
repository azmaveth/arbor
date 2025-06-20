defmodule Arbor.Security.FastAuthorizer do
  @moduledoc """
  Fast-path authorization that bypasses the SecurityKernel GenServer.

  This module provides read-only authorization checks directly against
  the ETS cache and database, avoiding the serialization bottleneck
  of going through the central GenServer.

  Use this for high-frequency authorization checks where eventual
  consistency is acceptable (e.g., recently revoked capabilities
  might still be authorized for a few milliseconds).
  """

  alias Arbor.Contracts.Core.Capability
  alias Arbor.Security.{CapabilityStore, ProductionEnforcer}

  require Logger

  @doc """
  Perform fast authorization check without going through SecurityKernel.

  This is suitable for read-heavy workloads where slight eventual
  consistency is acceptable. For operations that modify state
  (grant, revoke, delegate), you must use SecurityKernel.
  """
  @spec authorize(keyword()) :: {:ok, :authorized} | {:error, term()}
  def authorize(opts) do
    capability = Keyword.fetch!(opts, :capability)
    resource_uri = Keyword.fetch!(opts, :resource_uri)
    operation = Keyword.fetch!(opts, :operation)
    context = Keyword.get(opts, :context, %{})

    # Track fast-path usage
    :telemetry.execute(
      [:arbor, :security, :fast_auth, :attempt],
      %{count: 1},
      %{principal_id: Map.get(capability, :principal_id, "unknown")}
    )

    # Create a minimal enforcer state with direct access to stores
    enforcer_state = %{
      capability_store: CapabilityStore
    }

    # Use the production enforcer directly
    case ProductionEnforcer.authorize(
           capability,
           resource_uri,
           operation,
           context,
           enforcer_state
         ) do
      {:ok, :authorized} = result ->
        # Log successful fast-path authorization
        :telemetry.execute(
          [:arbor, :security, :fast_auth, :success],
          %{count: 1},
          %{principal_id: Map.get(capability, :principal_id, "unknown")}
        )

        result

      {:error, reason} = error ->
        # Log failed authorization
        :telemetry.execute(
          [:arbor, :security, :fast_auth, :denied],
          %{count: 1},
          %{principal_id: Map.get(capability, :principal_id, "unknown"), reason: reason}
        )

        error
    end
  end

  @doc """
  Batch authorization check for multiple resources.

  Useful for checking if a principal has access to multiple resources
  at once, avoiding multiple round trips.
  """
  @spec authorize_batch(Capability.t(), [String.t()], atom(), map()) ::
          {:ok, %{authorized: [String.t()], denied: [String.t()]}}
  def authorize_batch(capability, resource_uris, operation, context \\ %{}) do
    results =
      Enum.reduce(resource_uris, %{authorized: [], denied: []}, fn uri, acc ->
        case authorize(
               capability: capability,
               resource_uri: uri,
               operation: operation,
               context: context
             ) do
          {:ok, :authorized} ->
            %{acc | authorized: [uri | acc.authorized]}

          {:error, _reason} ->
            %{acc | denied: [uri | acc.denied]}
        end
      end)

    # Reverse to maintain order
    {:ok,
     %{
       authorized: Enum.reverse(results.authorized),
       denied: Enum.reverse(results.denied)
     }}
  end

  @doc """
  Check if a capability is still valid (not revoked or expired).

  This is a lightweight check that only validates the capability itself,
  not the full authorization chain.
  """
  @spec capability_valid?(Capability.t()) :: boolean()
  def capability_valid?(%Capability{} = capability) do
    # Check expiration first (local check)
    if Capability.valid?(capability) do
      # Then check revocation status in cache/database
      case CapabilityStore.get_capability_cached(capability.id) do
        {:ok, _stored} -> true
        {:error, :not_found} -> false
      end
    else
      false
    end
  end

  @doc """
  Prefetch and warm the cache for a set of capability IDs.

  Useful before performing many authorization checks to ensure
  the cache is warm and minimize database hits.
  """
  @spec prefetch_capabilities([String.t()]) :: :ok
  def prefetch_capabilities(capability_ids) when is_list(capability_ids) do
    # Attempt to load all capabilities to warm the cache
    # This happens in parallel for efficiency
    tasks =
      Enum.map(capability_ids, fn id ->
        Task.async(fn ->
          CapabilityStore.get_capability(id)
        end)
      end)

    # Wait for all to complete (with timeout)
    Task.await_many(tasks, 5_000)

    :ok
  end
end
