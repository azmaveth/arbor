defmodule Arbor.Security.PolicyEngine do
  @moduledoc """
  Concrete policy engine implementation for system-wide security rules.

  This module implements various security policies that apply globally,
  independent of individual capabilities. Examples include:

  - Rate limiting per principal
  - Time-based access restrictions
  - Resource-specific security policies
  - Compliance and regulatory requirements
  - Multi-factor authentication requirements
  """

  alias Arbor.Security.Policies.{RateLimiter, ResourcePolicies, TimeRestrictions}

  require Logger

  @doc """
  Check if an operation is allowed according to system policies.

  This is called by the ProductionEnforcer after capability validation
  but before final authorization.
  """
  @spec check_policies(atom(), String.t(), map(), map()) :: :ok | {:error, term()}
  def check_policies(operation, resource_uri, context, state) do
    policies = [
      # Rate limiting check
      &check_rate_limit/4,

      # Time-based restrictions
      &check_time_restrictions/4,

      # Resource-specific policies
      &check_resource_policies/4,

      # Compliance policies
      &check_compliance_requirements/4,

      # Security level requirements
      &check_security_level/4
    ]

    # Run all policies, stop on first violation
    Enum.reduce_while(policies, :ok, fn policy, :ok ->
      case policy.(operation, resource_uri, context, state) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Rate limiting
  defp check_rate_limit(operation, _resource_uri, context, _state) do
    principal_id = Map.get(context, :principal_id, "unknown")

    case RateLimiter.check_rate(principal_id, operation) do
      {:ok, _remaining} ->
        :ok

      {:error, :rate_exceeded} ->
        Logger.warning("Rate limit exceeded for #{principal_id} on #{operation}")

        :telemetry.execute(
          [:arbor, :security, :policy, :violation],
          %{count: 1},
          %{principal_id: principal_id, policy: :rate_limit, operation: operation}
        )

        {:error, :rate_limit_exceeded}
    end
  end

  # Time-based restrictions
  defp check_time_restrictions(_operation, resource_uri, context, _state) do
    # Check if resource has time restrictions
    case TimeRestrictions.get_restrictions(resource_uri) do
      nil ->
        :ok

      restrictions ->
        if TimeRestrictions.allowed_now?(restrictions, context) do
          :ok
        else
          {:error, :outside_allowed_hours}
        end
    end
  end

  # Resource-specific policies
  defp check_resource_policies(operation, resource_uri, context, _state) do
    # Extract resource type from URI
    resource_type = extract_resource_type(resource_uri)

    case resource_type do
      "fs" ->
        # File system specific policies
        check_fs_policies(operation, resource_uri, context)

      "api" ->
        # API specific policies
        check_api_policies(operation, resource_uri, context)

      "tool" ->
        # Tool execution policies
        check_tool_policies(operation, resource_uri, context)

      _ ->
        # Unknown resource type, allow by default
        :ok
    end
  end

  # Compliance requirements
  defp check_compliance_requirements(_operation, resource_uri, context, _state) do
    # Check if resource contains sensitive data
    if ResourcePolicies.sensitive?(resource_uri) do
      # Require additional authentication for sensitive resources
      case Map.get(context, :mfa_verified, false) do
        true ->
          :ok

        false ->
          Logger.info("MFA required for sensitive resource: #{resource_uri}")
          {:error, :mfa_required}
      end
    else
      :ok
    end
  end

  # Security level requirements
  defp check_security_level(_operation, resource_uri, context, _state) do
    required_level = ResourcePolicies.required_security_level(resource_uri)
    actual_level = Map.get(context, :security_level, 0)

    if actual_level >= required_level do
      :ok
    else
      {:error, {:insufficient_security_level, required_level, actual_level}}
    end
  end

  # Helper functions

  defp extract_resource_type(uri) do
    case String.split(uri, "/") do
      ["arbor:", "", type | _] -> type
      _ -> "unknown"
    end
  end

  defp check_fs_policies(:write, resource_uri, _context) do
    # Don't allow writes to system directories
    if String.contains?(resource_uri, "/system/") do
      {:error, :system_directory_write_denied}
    else
      :ok
    end
  end

  defp check_fs_policies(_operation, _resource_uri, _context), do: :ok

  defp check_api_policies(:call, resource_uri, context) do
    # Check if external API calls are allowed
    if String.contains?(resource_uri, "/external/") do
      case Map.get(context, :external_api_allowed, false) do
        true -> :ok
        false -> {:error, :external_api_not_allowed}
      end
    else
      :ok
    end
  end

  defp check_api_policies(_operation, _resource_uri, _context), do: :ok

  defp check_tool_policies(:execute, resource_uri, context) do
    # Check if dangerous tools require approval
    if ResourcePolicies.dangerous_tool?(resource_uri) do
      case Map.get(context, :admin_approved, false) do
        true -> :ok
        false -> {:error, :requires_admin_approval}
      end
    else
      :ok
    end
  end

  defp check_tool_policies(_operation, _resource_uri, _context), do: :ok
end

defmodule Arbor.Security.Policies.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for principals.
  """

  use GenServer

  @default_tokens 100
  # tokens per second
  @default_refill_rate 10

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check_rate(principal_id, operation) do
    GenServer.call(__MODULE__, {:check_rate, principal_id, operation})
  end

  @impl true
  def init(_opts) do
    # ETS table for rate limit buckets
    :ets.new(:rate_limit_buckets, [:named_table, :public, :set])

    # Schedule periodic token refill
    schedule_refill()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:check_rate, principal_id, _operation}, _from, state) do
    # Get or create bucket
    bucket =
      case :ets.lookup(:rate_limit_buckets, principal_id) do
        [] ->
          new_bucket = %{tokens: @default_tokens, last_refill: System.monotonic_time()}
          :ets.insert(:rate_limit_buckets, {principal_id, new_bucket})
          new_bucket

        [{^principal_id, bucket}] ->
          bucket
      end

    # Check if we have tokens
    if bucket.tokens > 0 do
      # Consume a token
      new_bucket = %{bucket | tokens: bucket.tokens - 1}
      :ets.insert(:rate_limit_buckets, {principal_id, new_bucket})
      {:reply, {:ok, new_bucket.tokens}, state}
    else
      {:reply, {:error, :rate_exceeded}, state}
    end
  end

  @impl true
  def handle_info(:refill_tokens, state) do
    # Refill all buckets
    now = System.monotonic_time()

    :ets.foldl(
      fn {principal_id, bucket}, acc ->
        elapsed = System.convert_time_unit(now - bucket.last_refill, :native, :second)
        tokens_to_add = elapsed * @default_refill_rate

        if tokens_to_add >= 1 do
          new_tokens = min(bucket.tokens + trunc(tokens_to_add), @default_tokens)
          new_bucket = %{tokens: new_tokens, last_refill: now}
          :ets.insert(:rate_limit_buckets, {principal_id, new_bucket})
        end

        acc
      end,
      :ok,
      :rate_limit_buckets
    )

    schedule_refill()
    {:noreply, state}
  end

  defp schedule_refill do
    # Every second
    Process.send_after(self(), :refill_tokens, 1_000)
  end
end

defmodule Arbor.Security.Policies.TimeRestrictions do
  @moduledoc """
  Time-based access restrictions for resources.
  """

  # Hardcoded for now, could be loaded from config/database
  @restrictions %{
    "arbor://fs/write/financial/" => %{
      # 9 AM to 5 PM
      allowed_hours: {9, 17},
      allowed_days: [:monday, :tuesday, :wednesday, :thursday, :friday],
      timezone: "UTC"
    }
  }

  def get_restrictions(resource_uri) do
    Enum.find_value(@restrictions, fn {prefix, restrictions} ->
      if String.starts_with?(resource_uri, prefix), do: restrictions
    end)
  end

  def allowed_now?(restrictions, _context) do
    now = DateTime.utc_now()
    day_of_week = Date.day_of_week(now)
    hour = now.hour

    # Convert numeric day to atom
    day_atom =
      [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]
      |> Enum.at(day_of_week - 1)

    # Check day
    day_allowed = day_atom in restrictions.allowed_days

    # Check hour
    {start_hour, end_hour} = restrictions.allowed_hours
    hour_allowed = hour >= start_hour and hour < end_hour

    day_allowed and hour_allowed
  end
end

defmodule Arbor.Security.Policies.ResourcePolicies do
  @moduledoc """
  Resource-specific security policies.
  """

  def sensitive_patterns do
    [
      ~r/\/secrets?\//,
      ~r/\/credentials?\//,
      ~r/\/keys?\//,
      ~r/\.pem$/,
      ~r/\.key$/
    ]
  end

  @dangerous_tools [
    "arbor://tool/execute/system_command",
    "arbor://tool/execute/database_admin",
    "arbor://tool/execute/network_scanner"
  ]

  @security_levels %{
    "arbor://fs/read/public/" => 0,
    "arbor://fs/read/internal/" => 1,
    "arbor://fs/write/" => 2,
    "arbor://api/call/internal/" => 2,
    "arbor://api/call/external/" => 3,
    "arbor://tool/execute/" => 3
  }

  def sensitive?(resource_uri) do
    Enum.any?(sensitive_patterns(), &Regex.match?(&1, resource_uri))
  end

  def dangerous_tool?(resource_uri) do
    resource_uri in @dangerous_tools
  end

  def required_security_level(resource_uri) do
    # Find the most specific matching pattern
    @security_levels
    |> Enum.filter(fn {pattern, _level} -> String.starts_with?(resource_uri, pattern) end)
    |> Enum.max_by(fn {pattern, _level} -> String.length(pattern) end, fn -> {"", 0} end)
    |> elem(1)
  end
end
