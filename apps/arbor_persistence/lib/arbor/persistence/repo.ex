defmodule Arbor.Persistence.Repo do
  @moduledoc """
  Ecto repository for Arbor persistence layer.

  Provides database connectivity and query execution for the PostgreSQL backend.
  Configured for event sourcing with optimistic locking and transaction support.
  """

  use Ecto.Repo,
    otp_app: :arbor_persistence,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Dynamically loads the repository url from the DATABASE_URL environment variable.
  """
  @spec init(atom(), keyword()) :: {:ok, keyword()}
  def init(_, opts) do
    {:ok, Keyword.put(opts, :url, System.get_env("DATABASE_URL"))}
  end
end
