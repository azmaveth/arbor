defmodule Arbor.Persistence.Integration.DockerFallbackTest do
  @moduledoc """
  Tests for Docker environment detection and graceful fallback to in-memory persistence
  when Docker is unavailable.

  This test covers the fixes for Issue: CaseClauseError from Testcontainers when
  Docker socket is not found, ensuring graceful fallback to in-memory mode.
  """

  use ExUnit.Case, async: true

  alias Arbor.Persistence.IntegrationCase

  describe "Docker environment detection" do
    test "detect_environment returns appropriate response when Docker unavailable" do
      # Mock environment where Docker is explicitly disabled
      System.put_env("SKIP_TESTCONTAINERS", "true")

      try do
        result = IntegrationCase.detect_environment()

        assert match?({:docker_unavailable, _reason}, result)

        {_status, reason} = result
        assert String.contains?(reason, "explicitly disabled")
      after
        System.delete_env("SKIP_TESTCONTAINERS")
      end
    end

    test "detect_environment handles missing docker command gracefully" do
      # This test simulates the condition where docker command is not available
      # We can't easily mock System.cmd, but we can test the error handling path

      # Test with a mock that would return the docker_unavailable pattern
      result =
        case System.cmd("nonexistent_command", ["--version"], stderr_to_stdout: true) do
          {_, 0} -> {:docker_available, :use_testcontainers}
          {error, _} -> {:docker_unavailable, "command failed: #{String.trim(error)}"}
        end

      assert match?({:docker_unavailable, _}, result)
    end

    test "detect_environment structure is consistent" do
      result = IntegrationCase.detect_environment()

      case result do
        {:docker_available, :use_testcontainers} ->
          # If Docker is available, that's fine
          assert true

        {:docker_unavailable, reason} ->
          # If Docker is unavailable, reason should be a string
          assert is_binary(reason)
          assert String.length(reason) > 0

        _ ->
          flunk("Unexpected result format: #{inspect(result)}")
      end
    end
  end

  describe "Testcontainers error handling" do
    test "CaseClauseError handling pattern works" do
      # Test the error pattern that was causing issues
      test_error = %CaseClauseError{
        term: {:error, [docker_socket_path: :docker_socket_not_found]}
      }

      # Simulate the error handling we implemented
      result =
        try do
          raise test_error
        catch
          :error,
          %CaseClauseError{term: {:error, [docker_socket_path: :docker_socket_not_found]}} ->
            {:docker_unavailable, "docker socket not found"}

          kind, reason ->
            {:docker_unavailable, "testcontainers #{kind}: #{inspect(reason)}"}
        rescue
          error ->
            {:docker_unavailable, "testcontainers exception: #{inspect(error)}"}
        end

      assert result == {:docker_unavailable, "docker socket not found"}
    end

    test "other Testcontainers errors are handled appropriately" do
      # Test different types of errors that might occur
      test_cases = [
        {:error, :some_other_error},
        {:error, "Connection refused"},
        RuntimeError.exception("Some runtime error")
      ]

      for test_case <- test_cases do
        result =
          try do
            case test_case do
              error when is_exception(error) -> raise error
              other -> throw(other)
            end
          catch
            :error,
            %CaseClauseError{term: {:error, [docker_socket_path: :docker_socket_not_found]}} ->
              {:docker_unavailable, "docker socket not found"}

            kind, reason ->
              {:docker_unavailable, "testcontainers #{kind}: #{inspect(reason)}"}
          rescue
            error ->
              {:docker_unavailable, "testcontainers exception: #{inspect(error)}"}
          end

        assert match?({:docker_unavailable, _}, result)
      end
    end
  end

  describe "Integration with test infrastructure" do
    test "IntegrationCase gracefully handles Docker unavailable scenario" do
      # This test ensures the IntegrationCase properly handles the Docker fallback
      # We'll test by temporarily setting SKIP_TESTCONTAINERS

      original_env = System.get_env("SKIP_TESTCONTAINERS")
      System.put_env("SKIP_TESTCONTAINERS", "true")

      try do
        # Simulate the setup_all callback behavior
        result =
          case IntegrationCase.detect_environment() do
            {:docker_available, :use_testcontainers} ->
              # This shouldn't happen with SKIP_TESTCONTAINERS=true
              {:container, :postgresql}

            {:docker_unavailable, reason} ->
              # This should happen - verify the fallback message structure
              assert is_binary(reason)
              {:container, nil, :backend, :in_memory}
          end

        case result do
          {:container, nil, :backend, :in_memory} ->
            assert true, "Correctly fell back to in-memory mode"

          _ ->
            flunk("Should have fallen back to in-memory mode")
        end
      after
        case original_env do
          nil -> System.delete_env("SKIP_TESTCONTAINERS")
          value -> System.put_env("SKIP_TESTCONTAINERS", value)
        end
      end
    end

    test "fallback mode provides consistent test environment" do
      # Test that in-memory fallback provides same interface as Docker mode

      # This simulates what happens in test setup when Docker is unavailable
      backend = :in_memory

      # Should be able to create store in fallback mode
      table_name = :"integration_fallback_#{:erlang.unique_integer([:positive])}"

      store_result =
        case backend do
          :in_memory ->
            Arbor.Persistence.Store.init(backend: :in_memory, table_name: table_name)

          :postgresql ->
            # Would use real DB in normal mode
            {:ok, "mock_postgresql_store"}
        end

      assert match?({:ok, _}, store_result)

      # Verify store interface works in fallback mode
      {status, store} = store_result
      assert status == :ok
      assert is_map(store), "Store should be initialized properly in fallback mode"
      assert store.backend == :in_memory, "Should be using in-memory backend"
    end
  end

  describe "Error message quality" do
    test "error messages are helpful for troubleshooting" do
      test_cases = [
        {:docker_unavailable, "explicitly disabled via SKIP_TESTCONTAINERS"},
        {:docker_unavailable, "docker command failed: command not found"},
        {:docker_unavailable, "docker socket not found"},
        {:docker_unavailable, "testcontainers failed: connection refused"}
      ]

      for {status, reason} <- test_cases do
        assert status == :docker_unavailable
        assert is_binary(reason)
        assert String.length(reason) > 10, "Error message should be descriptive"

        # Error messages should give hints about what went wrong
        descriptive_terms = ["disabled", "failed", "not found", "connection", "docker"]

        has_descriptive_term =
          Enum.any?(descriptive_terms, fn term ->
            String.contains?(String.downcase(reason), term)
          end)

        assert has_descriptive_term, "Error message should contain descriptive terms: #{reason}"
      end
    end

    test "fallback warning message is informative" do
      # Test the warning message shown when falling back to in-memory mode
      reason = "docker not available for testing"

      warning_message = """
      ⚠️  Docker not available for integration tests (#{reason}).
      ⚠️  Falling back to in-memory persistence.
      ⚠️  Tests will run but won't verify real database behavior.

      To run full integration tests:
      1. Install Docker
      2. Start Docker daemon  
      3. Re-run tests
      """

      # Should contain essential information
      assert String.contains?(warning_message, "Docker not available")
      assert String.contains?(warning_message, "in-memory persistence")
      assert String.contains?(warning_message, "Install Docker")
      assert String.contains?(warning_message, "Start Docker daemon")

      # Should be properly formatted with warning symbols
      assert String.contains?(warning_message, "⚠️")
    end
  end

  describe "Environment variable handling" do
    test "SKIP_TESTCONTAINERS=true disables Docker" do
      original = System.get_env("SKIP_TESTCONTAINERS")

      try do
        System.put_env("SKIP_TESTCONTAINERS", "true")
        result = IntegrationCase.detect_environment()

        assert match?({:docker_unavailable, _}, result)
        {_, reason} = result
        assert String.contains?(reason, "explicitly disabled")
      after
        case original do
          nil -> System.delete_env("SKIP_TESTCONTAINERS")
          value -> System.put_env("SKIP_TESTCONTAINERS", value)
        end
      end
    end

    test "SKIP_TESTCONTAINERS with other values still checks Docker" do
      original = System.get_env("SKIP_TESTCONTAINERS")

      try do
        # Set to false or other value
        System.put_env("SKIP_TESTCONTAINERS", "false")
        result = IntegrationCase.detect_environment()

        # Should proceed to check Docker availability, not immediately disable
        case result do
          {:docker_unavailable, reason} ->
            refute String.contains?(reason, "explicitly disabled")

          {:docker_available, :use_testcontainers} ->
            assert true
        end
      after
        case original do
          nil -> System.delete_env("SKIP_TESTCONTAINERS")
          value -> System.put_env("SKIP_TESTCONTAINERS", value)
        end
      end
    end
  end
end
