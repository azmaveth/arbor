defmodule Arbor.Types do
  @moduledoc """
  Common types used throughout the Arbor system.

  This module defines all shared type definitions and guards. It provides the
  foundation for type safety across the distributed agent system.

  For functions that create, parse, or validate these types, see the
  `Arbor.Identifiers` module.

  ## Type Categories

  ### Identifiers
  - `agent_id` - Unique agent identifier
  - `session_id` - Session identifier
  - `capability_id` - Security capability identifier
  - `trace_id` - Distributed tracing identifier
  - `execution_id` - Execution context identifier

  ### Resource Addressing
  - `resource_uri` - Resource identifier URI
  - `agent_uri` - Agent address URI

  ### System Types
  - `agent_type` - Classification of agent functionality
  - `resource_type` - Classification of resource types
  - `operation` - Operations that can be performed
  """

  # Type definitions
  @type agent_id :: String.t()
  @type session_id :: String.t()
  @type capability_id :: String.t()
  @type trace_id :: String.t()
  @type execution_id :: String.t()
  @type resource_uri :: String.t()
  @type agent_uri :: String.t()
  @type timestamp :: DateTime.t()

  @type resource_type :: :fs | :api | :db | :tool | :agent | :network
  @type operation :: :read | :write | :execute | :delete | :list | :call
  @type agent_type :: :coordinator | :tool_executor | :llm | :export | :worker | :gateway

  @type error :: {:error, error_reason()}
  @type error_reason :: atom() | String.t() | map()

  # Guards for compile-time type checking
  defguard is_resource_type(type) when type in [:fs, :api, :db, :tool, :agent, :network]
  defguard is_operation(op) when op in [:read, :write, :execute, :delete, :list, :call]

  defguard is_agent_type(type)
           when type in [:coordinator, :tool_executor, :llm, :export, :worker, :gateway]
end
