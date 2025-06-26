defmodule Arbor.Contracts.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: Arbor.Contracts.Worker.start_link(arg)
      # {Arbor.Contracts.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Arbor.Contracts.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
