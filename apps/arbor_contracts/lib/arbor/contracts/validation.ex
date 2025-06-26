defmodule Arbor.Contracts.Validation do
  @moduledoc """
  Runtime validation infrastructure for Arbor contracts using Norm.

  This module provides selective runtime validation for critical contract
  boundaries while maintaining performance through environment-based toggles.

  ## Usage

      # In your module that needs validation
      alias Arbor.Contracts.Validation

      case Validation.validate(data, schema) do
        {:ok, validated_data} ->
          # Process validated data
          {:ok, result}

        {:error, reason} ->
          # Handle validation error
          {:error, {:validation_failed, reason}}
      end

  ## Configuration

  Runtime validation can be enabled/disabled per environment:

      # config/dev.exs
      config :arbor_contracts, enable_validation: true

      # config/prod.exs
      config :arbor_contracts, enable_validation: false
  """

  require Logger

  @doc """
  Validates data against a Norm schema if validation is enabled.

  Returns `{:ok, data}` if validation passes or is disabled.
  Returns `{:error, reason}` if validation fails.
  """
  @spec validate(any(), any()) :: {:ok, any()} | {:error, any()}
  def validate(data, schema) do
    if is_enabled?() do
      validate_with_norm(data, schema)
    else
      # Validation disabled - pass through without checking
      {:ok, data}
    end
  end

  defp validate_with_norm(data, schema) do
    case Norm.conform(data, schema) do
      {:ok, conformed_data} ->
        {:ok, conformed_data}

      {:error, errors} ->
        reason = format_validation_errors(errors)
        log_validation_failure(data, schema, reason)
        {:error, reason}
    end
  rescue
    exception ->
      reason = "Validation error: #{Exception.message(exception)}"
      log_validation_failure(data, schema, reason)
      {:error, reason}
  end

  @doc """
  Validates data and raises on validation failure.

  Only use this for cases where validation failure should crash the process.
  """
  @spec validate!(any(), any()) :: any()
  def validate!(data, schema) do
    case validate(data, schema) do
      {:ok, validated_data} -> validated_data
      {:error, reason} -> raise ArgumentError, "Validation failed: #{reason}"
    end
  end

  @doc """
  Returns true if runtime validation is enabled.
  """
  @spec is_enabled?() :: boolean()
  def is_enabled? do
    Application.get_env(:arbor_contracts, :enable_validation, false)
  end

  defp format_validation_errors(errors) do
    Enum.map_join(errors, "; ", fn error ->
      case error do
        %{path: path, message: message} ->
          "#{Enum.join(path, ".")}: #{message}"

        %{message: message} ->
          message

        # Handle selection/2 validation errors for required fields
        %{path: path, spec: ":required"} ->
          "#{Enum.join(path, ".")}: required field missing"

        # Handle selection/2 validation errors with other specs
        %{path: path, spec: spec} when is_binary(spec) ->
          "#{Enum.join(path, ".")}: #{spec}"

        error when is_binary(error) ->
          error

        _ ->
          "Unknown validation error: #{inspect(error)}"
      end
    end)
  end

  defp log_validation_failure(data, schema, reason) do
    Logger.warning("Contract validation failed",
      data: inspect(data, limit: 100),
      schema: inspect(schema, limit: 50),
      reason: reason,
      validation_enabled: is_enabled?()
    )

    # Emit telemetry event for monitoring (only if telemetry is available)
    if Code.ensure_loaded?(:telemetry) do
      :telemetry.execute(
        [:arbor, :contracts, :validation, :failed],
        %{count: 1},
        %{reason: reason, schema: inspect(schema, limit: 50)}
      )
    end
  end
end
