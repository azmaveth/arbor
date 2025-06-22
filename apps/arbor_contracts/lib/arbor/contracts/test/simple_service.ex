defmodule Arbor.Contracts.Test.SimpleService do
  @moduledoc """
  A simple contract for testing the Mix generator.
  This contract defines the behaviour for a simple service that can be started,
  stopped, and queried for status.
  """

  @doc """
  Starts the service.
  """
  @callback start_service(arg :: any()) :: :ok | {:error, any()}

  @doc """
  Stops the service.
  """
  @callback stop_service() :: :ok | {:error, any()}

  @doc """
  Gets the status of the service.
  """
  @callback get_status() :: {:ok, atom()} | {:error, any()}
end
