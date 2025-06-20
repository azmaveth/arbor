defmodule Arbor.Security.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Arbor.Security.{
    AuditLogger,
    CapabilityStore,
    Kernel,
    Policies.RateLimiter,
    Repo,
    Telemetry
  }

  @impl true
  def start(_type, _args) do
    # Setup telemetry handlers
    Telemetry.setup()

    # Different children for test vs dev/prod
    children =
      if Application.get_env(:arbor_security, :use_mock_db, false) do
        # Test mode - minimal services, let tests control everything
        [
          # Only start telemetry monitoring
          Telemetry
          # All other services (kernel, stores, rate limiter) will be started by tests
        ]
      else
        # Dev/prod mode - start everything including repo
        [
          # Start the Ecto repository
          Repo,
          # Start policy services
          RateLimiter,
          # Start telemetry monitoring
          Telemetry,
          # Start the security kernel and services
          Kernel,
          CapabilityStore,
          AuditLogger
        ]
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Arbor.Security.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
