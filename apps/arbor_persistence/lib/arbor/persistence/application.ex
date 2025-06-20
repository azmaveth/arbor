defmodule Arbor.Persistence.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Event journal writer for batched writes
      Arbor.Persistence.EventJournal

      # NOTE: Repo is started only when needed for integration tests
      # to avoid requiring database for unit tests
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Arbor.Persistence.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
