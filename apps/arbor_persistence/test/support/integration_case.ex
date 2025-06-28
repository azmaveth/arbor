defmodule Arbor.Persistence.IntegrationCase do
  @moduledoc """
  ExUnit case template for integration tests with automatic environment detection.

  This case template provides:
  - PostgreSQL Testcontainer when Docker is available
  - Automatic fallback to FastCase when Docker is unavailable  
  - Proper isolation using Ecto.Adapters.SQL.Sandbox
  - Same API as FastCase for consistency
  - Integration with Arbor's event sourcing patterns

  ## Usage

      defmodule MyModule.IntegrationTest do
        use Arbor.Persistence.IntegrationCase

        @tag :integration
        test "performs realistic database operations", %{store: store} do
          event = build_test_event(:agent_started)
          
          {:ok, _version} = Store.append_events("test-stream", [event], -1, store)
          {:ok, events} = Store.read_events("test-stream", 0, :latest, store)
          
          # Verify JSON serialization through real database
          retrieved_event = hd(events)
          assert retrieved_event.data["agent_type"] == "test_agent"
        end
      end

  ## Environment Detection

  This case automatically detects the environment:
  - **Docker Available**: Uses PostgreSQL Testcontainer for realistic testing
  - **Docker Unavailable**: Falls back to FastCase with clear messaging
  - **CI Environment**: Respects CI configuration and test exclusion tags

  ## Test Tags

  All tests using this case are automatically tagged with:
  - `:integration` - Indicates integration test requiring real database
  - `async: false` - Required for Ecto Sandbox shared mode

  ## Provided Helpers

  Inherits all helpers from FastCase:
  - `build_test_event/2` - Creates test events with realistic data
  - `build_test_snapshot/2` - Creates test snapshots  
  - `unique_stream_id/1` - Generates unique stream identifiers
  - `build_event_sequence/3` - Creates multiple events for testing
  """

  use ExUnit.CaseTemplate

  alias Arbor.Persistence.Store

  using do
    quote do
      # Set async to false for all tests using this case.
      # This is required for the Ecto Sandbox shared mode.
      use ExUnit.Case, async: false

      # Import common modules for convenience in tests
      import Ecto
      import Ecto.Query
      import Arbor.Persistence.FastCase

      # Standard aliases for consistency with FastCase
      alias Arbor.Contracts.Events.Event, as: ContractEvent
      alias Arbor.Contracts.Persistence.Snapshot
      alias Arbor.Persistence.Store
      alias Arbor.Persistence.Repo
    end
  end

  # Tag all tests using this case
  @moduletag :integration

  setup_all do
    case detect_environment() do
      {:docker_available, :use_testcontainers} ->
        {:ok, container} = start_containers()
        [container: container, backend: :postgresql]

      {:docker_unavailable, reason} ->
        IO.puts("""

        ⚠️  Docker not available for integration tests (#{reason}).
        ⚠️  Falling back to in-memory persistence.
        ⚠️  Tests will run but won't verify real database behavior.

        To run full integration tests:
        1. Install Docker
        2. Start Docker daemon  
        3. Re-run tests

        """)

        [container: nil, backend: :in_memory]
    end
  end

  def detect_environment do
    cond do
      # Check if explicitly disabled
      System.get_env("SKIP_TESTCONTAINERS") == "true" ->
        {:docker_unavailable, "explicitly disabled via SKIP_TESTCONTAINERS"}

      # Check if Docker socket exists and docker command works (Unix systems)
      File.exists?("/var/run/docker.sock") ->
        case System.cmd("docker", ["info"], env: [], stderr_to_stdout: true) do
          {_output, 0} ->
            # Additional check: can we actually start Testcontainers?
            try do
              case Testcontainers.start_link() do
                {:ok, pid} ->
                  # Clean up the test process
                  GenServer.stop(pid)
                  {:docker_available, :use_testcontainers}

                {:error, reason} ->
                  {:docker_unavailable, "testcontainers failed: #{inspect(reason)}"}
              end
            rescue
              error -> {:docker_unavailable, "testcontainers exception: #{inspect(error)}"}
            catch
              # Handle CaseClauseError from Testcontainers when Docker socket not found
              :error,
              %CaseClauseError{term: {:error, [docker_socket_path: :docker_socket_not_found]}} ->
                {:docker_unavailable, "docker socket not found"}

              # Handle other thrown errors
              kind, reason ->
                {:docker_unavailable, "testcontainers #{kind}: #{inspect(reason)}"}
            end

          {error, _} ->
            {:docker_unavailable, "docker command failed: #{String.trim(error)}"}
        end

      # Try docker command anyway (Windows/other systems)
      true ->
        case System.cmd("docker", ["info"], env: [], stderr_to_stdout: true) do
          {_output, 0} ->
            # Additional check: can we actually start Testcontainers?
            try do
              case Testcontainers.start_link() do
                {:ok, pid} ->
                  # Clean up the test process
                  GenServer.stop(pid)
                  {:docker_available, :use_testcontainers}

                {:error, reason} ->
                  {:docker_unavailable, "testcontainers failed: #{inspect(reason)}"}
              end
            rescue
              error -> {:docker_unavailable, "testcontainers exception: #{inspect(error)}"}
            catch
              # Handle CaseClauseError from Testcontainers when Docker socket not found
              :error,
              %CaseClauseError{term: {:error, [docker_socket_path: :docker_socket_not_found]}} ->
                {:docker_unavailable, "docker socket not found"}

              # Handle other thrown errors
              kind, reason ->
                {:docker_unavailable, "testcontainers #{kind}: #{inspect(reason)}"}
            end

          {error, _} ->
            {:docker_unavailable, "docker not found: #{String.trim(error)}"}
        end
    end
  rescue
    error -> {:docker_unavailable, "detection failed: #{inspect(error)}"}
  end

  def start_containers do
    # Start Testcontainers GenServer
    {:ok, _} =
      try do
        case Testcontainers.start_link() do
          {:ok, pid} -> {:ok, pid}
          {:error, reason} -> raise "Failed to start Testcontainers: #{inspect(reason)}"
        end
      rescue
        error -> reraise "Failed to start Testcontainers: #{inspect(error)}", __STACKTRACE__
      catch
        # Handle CaseClauseError from Testcontainers when Docker socket not found
        :error, %CaseClauseError{term: {:error, [docker_socket_path: :docker_socket_not_found]}} ->
          raise "Docker socket not found - ensure Docker is running"

        # Handle other thrown errors
        kind, reason ->
          raise "Testcontainers #{kind}: #{inspect(reason)}"
      end

    # Define and start the PostgreSQL container
    container_config =
      Testcontainers.Container.new("postgres:15")
      |> Testcontainers.Container.with_environment("POSTGRES_USER", "postgres")
      |> Testcontainers.Container.with_environment("POSTGRES_PASSWORD", "postgres")
      |> Testcontainers.Container.with_environment("POSTGRES_DB", "arbor_persistence_test")
      |> Testcontainers.Container.with_exposed_port(5432)

    {:ok, container} = Testcontainers.start_container(container_config)

    # Get database port and wait for database to be ready
    db_port = Testcontainers.Container.mapped_port(container, 5432)

    # Simple wait for PostgreSQL to be ready
    :timer.sleep(3_000)

    config = [
      hostname: "localhost",
      port: db_port,
      username: "postgres",
      password: "postgres",
      database: "arbor_persistence_test",
      pool: Ecto.Adapters.SQL.Sandbox,
      # The following are good defaults for a test environment
      pool_size: 2
    ]

    # Reconfigure the repo to point to the container's database
    Arbor.Persistence.Repo.put_dynamic_repo(config)

    # Run migrations to set up the schema.
    migrations_path = Path.expand("priv/repo/migrations", Application.app_dir(:arbor_persistence))
    Ecto.Migrator.run(Arbor.Persistence.Repo, migrations_path, :up, all: true)

    {:ok, container: container}
  end

  setup %{backend: backend} = tags do
    case backend do
      :postgresql ->
        # Check out a connection from the sandbox for the test process
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arbor.Persistence.Repo)

        # Set the sandbox to shared mode
        unless tags[:async] do
          Ecto.Adapters.SQL.Sandbox.mode(Arbor.Persistence.Repo, {:shared, self()})
        end

        # Initialize PostgreSQL store 
        cache_table = :"cache_#{:erlang.unique_integer([:positive])}"
        {:ok, store} = Store.init(backend: :postgresql, cache_table: cache_table)

        %{store: store, test_backend: :postgresql}

      :in_memory ->
        # Initialize in-memory store (fallback mode)
        table_name = :"integration_fallback_#{:erlang.unique_integer([:positive])}"
        {:ok, store} = Store.init(backend: :in_memory, table_name: table_name)

        %{store: store, test_backend: :in_memory}
    end
  end

  setup tags do
    # Fallback for tests that don't have backend in context (shouldn't happen normally)
    if Map.has_key?(tags, :backend) do
      %{}
    else
      table_name = :"integration_fallback_#{:erlang.unique_integer([:positive])}"
      {:ok, store} = Store.init(backend: :in_memory, table_name: table_name)

      %{store: store, test_backend: :in_memory}
    end
  end
end
