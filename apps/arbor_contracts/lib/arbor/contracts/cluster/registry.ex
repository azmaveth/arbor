defmodule Arbor.Contracts.Cluster.Registry do
  @moduledoc """
  Contract for distributed registry operations using Horde.

  The registry provides distributed process registration and discovery
  across the Arbor cluster. It handles node failures, network partitions,
  and dynamic cluster membership changes while maintaining consistency.

  ## Design Principles

  - **Eventually Consistent**: Registry state converges across nodes
  - **Partition Tolerant**: Continues operating during network splits
  - **Self-Healing**: Automatically recovers from node failures
  - **Location Transparent**: Processes can be found regardless of node

  ## Registry Patterns

  1. **Name Registration**: Unique names across the cluster
  2. **Group Registration**: Multiple processes under a group
  3. **Metadata Storage**: Attach metadata to registrations
  4. **TTL Support**: Automatic expiration of registrations

  ## Example Implementation

      defmodule MyRegistry do
        @behaviour Arbor.Contracts.Cluster.Registry
        
        @impl true
        def register_name(name, pid, metadata, state) do
          case Horde.Registry.register(state.registry, name, pid, metadata) do
            {:ok, _} -> :ok
            {:error, {:already_registered, _}} -> {:error, :name_taken}
          end
        end
      end

  @version "1.0.0"
  """

  @type name :: any()
  @type group :: any()
  @type metadata :: map()
  @type state :: any()
  @type ttl :: pos_integer() | :infinity

  @type registry_error ::
          :name_taken
          | :not_registered
          | :group_not_found
          | :invalid_ttl
          | :registry_down
          | :node_not_connected
          | {:error, term()}

  @doc """
  Register a process with a unique name across the cluster.

  Names must be unique - attempting to register an already-used name
  will fail. The registration is automatically removed if the process dies.

  ## Parameters

  - `name` - Unique name for the process
  - `pid` - Process to register
  - `metadata` - Additional data to store with registration
  - `state` - Registry state

  ## Metadata

  Common metadata fields:
  - `:node` - Node where process is running
  - `:type` - Type of process (agent, service, etc.)
  - `:capabilities` - What the process can do
  - `:session_id` - Associated session

  ## Returns

  - `:ok` - Registration successful
  - `{:error, :name_taken}` - Name already registered
  - `{:error, reason}` - Registration failed

  ## Example

      Registry.register_name(
        {:agent, "agent_123"},
        self(),
        %{type: :llm_agent, capabilities: [:chat, :analysis]},
        state
      )
  """
  @callback register_name(
              name(),
              pid(),
              metadata(),
              state()
            ) :: :ok | {:error, registry_error()}

  @doc """
  Register a process under a group name.

  Groups allow multiple processes to be registered under the same name.
  Useful for worker pools, redundant services, or broadcast groups.

  ## Parameters

  - `group` - Group name
  - `pid` - Process to add to group
  - `metadata` - Process-specific metadata
  - `state` - Registry state

  ## Returns

  - `:ok` - Added to group successfully
  - `{:error, reason}` - Registration failed

  ## Example

      # Register multiple workers under same group
      Registry.register_group(:code_analyzers, worker1_pid, %{}, state)
      Registry.register_group(:code_analyzers, worker2_pid, %{}, state)
  """
  @callback register_group(
              group(),
              pid(),
              metadata(),
              state()
            ) :: :ok | {:error, registry_error()}

  @doc """
  Unregister a name from the registry.

  Explicitly removes a registration. This is optional as registrations
  are automatically removed when processes die.

  ## Parameters

  - `name` - Name to unregister
  - `state` - Registry state

  ## Returns

  - `:ok` - Unregistered successfully
  - `{:error, :not_registered}` - Name not found
  """
  @callback unregister_name(
              name(),
              state()
            ) :: :ok | {:error, registry_error()}

  @doc """
  Unregister a process from a group.

  Removes a specific process from a group while leaving other
  group members registered.

  ## Parameters

  - `group` - Group name
  - `pid` - Process to remove
  - `state` - Registry state

  ## Returns

  - `:ok` - Removed from group
  - `{:error, :not_registered}` - Process not in group
  """
  @callback unregister_group(
              group(),
              pid(),
              state()
            ) :: :ok | {:error, registry_error()}

  @doc """
  Look up a process by name.

  Returns the pid and metadata for a registered name.
  Works across the entire cluster.

  ## Parameters

  - `name` - Name to look up
  - `state` - Registry state

  ## Returns

  - `{:ok, {pid, metadata}}` - Process found
  - `{:error, :not_registered}` - Name not registered
  """
  @callback lookup_name(
              name(),
              state()
            ) :: {:ok, {pid(), metadata()}} | {:error, registry_error()}

  @doc """
  Look up all processes in a group.

  Returns all processes registered under a group name along
  with their metadata.

  ## Parameters

  - `group` - Group to look up
  - `state` - Registry state

  ## Returns

  - `{:ok, [{pid, metadata}]}` - Group members found
  - `{:ok, []}` - Group exists but empty
  - `{:error, :group_not_found}` - Group doesn't exist
  """
  @callback lookup_group(
              group(),
              state()
            ) :: {:ok, [{pid(), metadata()}]} | {:error, registry_error()}

  @doc """
  Update metadata for a registered name.

  Allows updating the metadata stored with a registration without
  re-registering the process.

  ## Parameters

  - `name` - Registered name
  - `metadata` - New metadata (replaces existing)
  - `state` - Registry state

  ## Returns

  - `:ok` - Metadata updated
  - `{:error, :not_registered}` - Name not found
  """
  @callback update_metadata(
              name(),
              metadata(),
              state()
            ) :: :ok | {:error, registry_error()}

  @doc """
  Register a name with a time-to-live.

  The registration will be automatically removed after the TTL expires,
  even if the process is still alive. Useful for temporary registrations.

  ## Parameters

  - `name` - Name to register
  - `pid` - Process to register
  - `ttl` - Time to live in milliseconds
  - `metadata` - Registration metadata
  - `state` - Registry state

  ## Returns

  - `:ok` - Registered with TTL
  - `{:error, reason}` - Registration failed

  ## Example

      # Register for 5 minutes
      Registry.register_with_ttl(
        {:temp_worker, "work_123"},
        self(),
        300_000,
        %{task: "analyze_code"},
        state
      )
  """
  @callback register_with_ttl(
              name(),
              pid(),
              ttl(),
              metadata(),
              state()
            ) :: :ok | {:error, registry_error()}

  @doc """
  List all registrations matching a pattern.

  Useful for discovery and monitoring. Returns all registrations
  whose names match the given pattern.

  ## Parameters

  - `pattern` - Match pattern (depends on implementation)
  - `state` - Registry state

  ## Pattern Examples

  - `{:agent, :_}` - All agent registrations
  - `{:service, :_, node()}` - All services on current node

  ## Returns

  - `{:ok, [{name, pid, metadata}]}` - Matching registrations
  """
  @callback match(
              pattern :: any(),
              state()
            ) :: {:ok, [{name(), pid(), metadata()}]} | {:error, registry_error()}

  @doc """
  Get count of registrations.

  Returns the total number of registered names in the cluster.
  Useful for monitoring and capacity planning.

  ## Returns

  - `{:ok, count}` - Number of registrations
  """
  @callback count(state()) :: {:ok, non_neg_integer()} | {:error, registry_error()}

  @doc """
  Monitor a registered name.

  Sets up monitoring so the caller will be notified if the
  registration changes (process dies, moves nodes, etc.).

  ## Parameters

  - `name` - Name to monitor
  - `state` - Registry state

  ## Returns

  - `{:ok, ref}` - Monitoring established, returns reference
  - `{:error, :not_registered}` - Name not found

  ## Notifications

  The caller will receive messages like:
  - `{:registry_down, ref, name, reason}`
  - `{:registry_conflict, ref, name, pids}`
  """
  @callback monitor(
              name(),
              state()
            ) :: {:ok, reference()} | {:error, registry_error()}

  @doc """
  Get registry health information.

  Returns information about the registry's distributed state,
  useful for monitoring and debugging.

  ## Returns

  Map containing:
  - `:node_count` - Number of nodes in registry cluster
  - `:registration_count` - Total registrations
  - `:conflict_count` - Number of naming conflicts
  - `:nodes` - List of connected nodes
  - `:sync_status` - Registry synchronization status
  """
  @callback health_check(state()) :: {:ok, map()} | {:error, registry_error()}

  @doc """
  Start the distributed registry infrastructure.

  Sets up the distributed registry infrastructure including Horde components.
  This is distinct from GenServer.init/1 and manages the registry component lifecycle.

  ## Options

  - `:name` - Registry name
  - `:delta_crdt_options` - Horde CRDT options
  - `:distribution_strategy` - How to distribute registrations

  ## Returns

  - `{:ok, state}` - Registry initialized
  - `{:error, reason}` - Initialization failed
  """
  @callback start_registry(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Handle node joining the cluster.

  Called when a new node joins. Registry should sync state
  with the new node.
  """
  @callback handle_node_up(node :: node(), state()) :: {:ok, state()}

  @doc """
  Handle node leaving the cluster.

  Called when a node leaves. Registry should handle any
  registrations that were on that node.
  """
  @callback handle_node_down(node :: node(), state()) :: {:ok, state()}

  @doc """
  Stop the distributed registry and clean up resources.

  This handles registry component shutdown and is distinct from GenServer.terminate/2.
  Should gracefully clean up all registry resources and state.
  """
  @callback stop_registry(reason :: term(), state()) :: :ok
end
