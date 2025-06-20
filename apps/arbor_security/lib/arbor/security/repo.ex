defmodule Arbor.Security.Repo do
  @moduledoc """
  Ecto repository for the security application.

  This repo handles all database operations for capabilities
  and audit events.
  """

  use Ecto.Repo,
    otp_app: :arbor_security,
    adapter: Ecto.Adapters.Postgres
end
