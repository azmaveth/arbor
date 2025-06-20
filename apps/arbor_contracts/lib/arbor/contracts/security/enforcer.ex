defmodule Arbor.Contracts.Security.Enforcer do
  @moduledoc """
  Defines the contract for security enforcement in the Arbor system.

  This behaviour establishes how capability-based security is enforced
  throughout the system. All security implementations must conform to
  this contract to ensure consistent authorization decisions.

  ## Security Model

  Arbor uses capability-based security where:
  - Every operation requires an explicit capability
  - Capabilities are unforgeable tokens with specific permissions
  - Capabilities can be delegated with reduced permissions
  - All security decisions are auditable

  ## Enforcement Flow

  1. Agent requests operation with capability
  2. Enforcer validates capability authenticity
  3. Enforcer checks capability permissions match request
  4. Enforcer verifies capability constraints
  5. Decision is made and audit event is generated

  ## Example Implementation

      defmodule MySecurityEnforcer do
        @behaviour Arbor.Contracts.Security.Enforcer
        
        @impl true
        def authorize(cap, resource_uri, operation, context, state) do
          with :ok <- validate_capability(cap),
               :ok <- check_permissions(cap, resource_uri, operation),
               :ok <- verify_constraints(cap, context) do
            emit_audit_event(:authorized, cap, resource_uri, operation)
            {:ok, :authorized}
          else
            {:error, reason} ->
              emit_audit_event(:denied, cap, resource_uri, operation, reason)
              {:error, {:authorization_denied, reason}}
          end
        end
      end

  @version "1.0.0"
  """

  alias Arbor.Contracts.Core.Capability
  alias Arbor.Contracts.Security.AuditEvent
  alias Arbor.Types

  @type state :: any()
  @type context :: map()
  @type decision :: :authorized | :denied

  @type authorization_error ::
          :capability_expired
          | :capability_revoked
          | :invalid_capability
          | :insufficient_permissions
          | :resource_not_found
          | :operation_not_allowed
          | :constraint_violation
          | {:custom_error, term()}

  @doc """
  Authorize an operation on a resource using a capability.

  This is the primary security decision point. It validates the capability
  and determines if the requested operation is allowed.

  ## Parameters

  - `capability` - The capability presented for authorization
  - `resource_uri` - URI of the resource being accessed
  - `operation` - Operation being requested (:read, :write, :execute, etc.)
  - `context` - Additional context for the authorization decision
  - `state` - Enforcer state

  ## Context

  The context map may include:
  - `:agent_id` - ID of the agent making the request
  - `:session_id` - Current session ID
  - `:trace_id` - Distributed trace ID
  - `:request_size` - Size of data being accessed/written
  - `:metadata` - Additional request metadata

  ## Returns

  - `{:ok, :authorized}` - Operation is allowed
  - `{:error, {:authorization_denied, reason}}` - Operation denied

  ## Example

      context = %{
        agent_id: "agent_123",
        session_id: "session_456",
        request_size: 1024
      }
      
      case Enforcer.authorize(capability, "arbor://fs/read/docs", :read, context, state) do
        {:ok, :authorized} -> perform_read()
        {:error, {:authorization_denied, reason}} -> handle_denial(reason)
      end
  """
  @callback authorize(
              capability :: Capability.t(),
              resource_uri :: Types.resource_uri(),
              operation :: Types.operation(),
              context :: context(),
              state :: state()
            ) :: {:ok, :authorized} | {:error, {:authorization_denied, authorization_error()}}

  @doc """
  Check if a capability is valid without performing authorization.

  This performs basic validation:
  - Signature verification (if signed)
  - Expiration check
  - Revocation check

  Use this for pre-flight checks or capability inspection.

  ## Returns

  - `{:ok, :valid}` - Capability is valid
  - `{:error, reason}` - Capability is invalid
  """
  @callback validate_capability(
              capability :: Capability.t(),
              state :: state()
            ) :: {:ok, :valid} | {:error, authorization_error()}

  @doc """
  Grant a new capability.

  Creates and stores a new capability grant. This should:
  - Generate a unique capability ID
  - Set appropriate expiration
  - Store in capability registry
  - Emit audit event

  ## Parameters

  - `principal_id` - Agent receiving the capability
  - `resource_uri` - Resource the capability grants access to
  - `constraints` - Additional constraints on capability use
  - `granter_id` - ID of the entity granting the capability
  - `state` - Enforcer state

  ## Constraints

  Common constraints include:
  - `:max_uses` - Maximum number of times capability can be used
  - `:time_window` - Time restrictions (e.g., business hours only)
  - `:rate_limit` - Maximum requests per time period
  - `:data_limit` - Maximum data size for operations

  ## Returns

  - `{:ok, capability}` - New capability successfully granted
  - `{:error, reason}` - Grant failed
  """
  @callback grant_capability(
              principal_id :: Types.agent_id(),
              resource_uri :: Types.resource_uri(),
              constraints :: map(),
              granter_id :: String.t(),
              state :: state()
            ) :: {:ok, Capability.t()} | {:error, term()}

  @doc """
  Revoke an existing capability.

  Immediately invalidates a capability. This should:
  - Mark capability as revoked
  - Prevent future use
  - Emit audit event
  - Optionally cascade to delegated capabilities

  ## Parameters

  - `capability_id` - ID of capability to revoke
  - `reason` - Reason for revocation
  - `revoker_id` - ID of entity revoking the capability
  - `cascade` - Whether to revoke delegated capabilities
  - `state` - Enforcer state

  ## Returns

  - `:ok` - Capability revoked successfully
  - `{:error, :not_found}` - Capability doesn't exist
  - `{:error, reason}` - Revocation failed
  """
  @callback revoke_capability(
              capability_id :: Types.capability_id(),
              reason :: atom() | String.t(),
              revoker_id :: String.t(),
              cascade :: boolean(),
              state :: state()
            ) :: :ok | {:error, term()}

  @doc """
  Delegate a capability to another principal.

  Creates a new capability with reduced permissions based on an existing
  capability. The delegated capability:
  - Has reduced or equal permissions
  - Has reduced delegation depth
  - Inherits parent constraints
  - Can add additional constraints

  ## Parameters

  - `parent_capability` - Capability being delegated
  - `delegate_to` - Agent receiving the delegation
  - `constraints` - Additional constraints for delegated capability
  - `delegator_id` - ID of agent doing the delegation
  - `state` - Enforcer state

  ## Returns

  - `{:ok, delegated_capability}` - Delegation successful
  - `{:error, :delegation_depth_exhausted}` - No more delegations allowed
  - `{:error, reason}` - Delegation failed
  """
  @callback delegate_capability(
              parent_capability :: Capability.t(),
              delegate_to :: Types.agent_id(),
              constraints :: map(),
              delegator_id :: String.t(),
              state :: state()
            ) :: {:ok, Capability.t()} | {:error, term()}

  @doc """
  List all capabilities for a principal.

  Returns all active (non-revoked, non-expired) capabilities
  granted to a specific agent.

  ## Parameters

  - `principal_id` - Agent to list capabilities for
  - `filters` - Optional filters
  - `state` - Enforcer state

  ## Filters

  - `:resource_type` - Filter by resource type (e.g., :fs, :api)
  - `:include_delegated` - Include capabilities delegated by this principal
  - `:include_expired` - Include expired capabilities

  ## Returns

  - `{:ok, capabilities}` - List of capabilities
  - `{:error, reason}` - Query failed
  """
  @callback list_capabilities(
              principal_id :: Types.agent_id(),
              filters :: keyword(),
              state :: state()
            ) :: {:ok, [Capability.t()]} | {:error, term()}

  @doc """
  Get audit trail for security events.

  Retrieves security audit events based on filters. Used for
  compliance, debugging, and security monitoring.

  ## Parameters

  - `filters` - Query filters
  - `state` - Enforcer state

  ## Filters

  - `:capability_id` - Events for specific capability
  - `:principal_id` - Events for specific agent
  - `:resource_uri` - Events for specific resource
  - `:event_type` - Filter by event type
  - `:from` - Start timestamp
  - `:to` - End timestamp
  - `:limit` - Maximum events to return

  ## Returns

  - `{:ok, events}` - List of audit events
  - `{:error, reason}` - Query failed
  """
  @callback get_audit_trail(
              filters :: keyword(),
              state :: state()
            ) :: {:ok, [AuditEvent.t()]} | {:error, term()}

  @doc """
  Check system-wide security policies.

  Evaluates if an operation would violate any system-wide policies,
  regardless of capabilities. Used for implementing defense-in-depth.

  ## Parameters

  - `operation` - Operation being requested
  - `resource_uri` - Target resource
  - `context` - Request context
  - `state` - Enforcer state

  ## Policy Examples

  - Rate limiting across all agents
  - Blocking access to sensitive resources during maintenance
  - Enforcing data loss prevention rules

  ## Returns

  - `:ok` - No policy violations
  - `{:error, {:policy_violation, policy_name}}` - Policy violated
  """
  @callback check_policies(
              operation :: Types.operation(),
              resource_uri :: Types.resource_uri(),
              context :: context(),
              state :: state()
            ) :: :ok | {:error, {:policy_violation, atom()}}

  @doc """
  Initialize the security enforcer.

  Called when the enforcer starts. Should set up any necessary
  state, connections, or background processes.

  ## Options

  - `:audit_backend` - Where to store audit events
  - `:capability_store` - Capability storage backend
  - `:policy_engine` - Policy evaluation engine

  ## Returns

  - `{:ok, state}` - Enforcer initialized
  - `{:error, reason}` - Initialization failed
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Clean up resources when shutting down.

  Called when the enforcer is terminating. Should close connections
  and clean up any resources.
  """
  @callback terminate(reason :: term(), state :: state()) :: :ok
end
