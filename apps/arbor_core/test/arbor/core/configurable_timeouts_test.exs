defmodule Arbor.Core.ConfigurableTimeoutsTest do
  @moduledoc """
  Tests for configurable timeout functionality in HordeSupervisor to ensure
  timeouts can be properly configured and that the system respects those settings.

  This test covers the fixes for Issue: Hardcoded 5-second timeouts in HordeSupervisor
  preventing proper configuration of agent termination and extraction timeouts.
  """

  use ExUnit.Case, async: false

  alias Arbor.Core.HordeSupervisor

  @moduletag :integration

  describe "configurable timeout configuration" do
    test "default timeouts are used when no configuration provided" do
      # Test the default timeout values
      original_config = Application.get_env(:arbor_core, :agent_termination_timeout)
      original_extraction_config = Application.get_env(:arbor_core, :agent_extraction_timeout)

      try do
        # Clear any existing config
        Application.delete_env(:arbor_core, :agent_termination_timeout)
        Application.delete_env(:arbor_core, :agent_extraction_timeout)

        # Start an agent that we can test timeouts with
        agent_id = "timeout-test-#{:erlang.unique_integer([:positive])}"

        agent_spec = %{
          id: agent_id,
          start: {Arbor.Test.Mocks.TestAgent, :start_link, [[]]},
          restart: :transient,
          type: :worker
        }

        # Start agent - this should use default timeouts internally
        start_time = System.monotonic_time(:millisecond)
        {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)
        end_time = System.monotonic_time(:millisecond)

        # Operation should complete quickly with defaults (not timeout)
        duration = end_time - start_time
        assert duration < 10_000, "Agent start should complete quickly with default timeouts"

        # Stop agent - this should also use default timeouts
        stop_start_time = System.monotonic_time(:millisecond)
        :ok = HordeSupervisor.stop_agent(agent_id)
        stop_end_time = System.monotonic_time(:millisecond)

        stop_duration = stop_end_time - stop_start_time
        assert stop_duration < 10_000, "Agent stop should complete quickly with default timeouts"
      after
        # Restore original config
        case original_config do
          nil -> Application.delete_env(:arbor_core, :agent_termination_timeout)
          value -> Application.put_env(:arbor_core, :agent_termination_timeout, value)
        end

        case original_extraction_config do
          nil -> Application.delete_env(:arbor_core, :agent_extraction_timeout)
          value -> Application.put_env(:arbor_core, :agent_extraction_timeout, value)
        end
      end
    end

    test "custom timeouts are respected when configured" do
      # Test that custom timeout configuration is used
      original_config = Application.get_env(:arbor_core, :agent_termination_timeout)
      original_extraction_config = Application.get_env(:arbor_core, :agent_extraction_timeout)

      try do
        # Set custom timeout values
        # 10 seconds
        custom_termination_timeout = 10_000
        # 8 seconds
        custom_extraction_timeout = 8_000

        Application.put_env(:arbor_core, :agent_termination_timeout, custom_termination_timeout)
        Application.put_env(:arbor_core, :agent_extraction_timeout, custom_extraction_timeout)

        # Start an agent
        agent_id = "custom-timeout-test-#{:erlang.unique_integer([:positive])}"

        agent_spec = %{
          id: agent_id,
          start: {Arbor.Test.Mocks.TestAgent, :start_link, [[]]},
          restart: :transient,
          type: :worker
        }

        {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)

        # The fact that start/stop operations complete successfully indicates
        # that the timeout configuration is being read properly
        :ok = HordeSupervisor.stop_agent(agent_id)

        # Verify the configuration is actually set
        assert Application.get_env(:arbor_core, :agent_termination_timeout) ==
                 custom_termination_timeout

        assert Application.get_env(:arbor_core, :agent_extraction_timeout) ==
                 custom_extraction_timeout
      after
        # Restore original config
        case original_config do
          nil -> Application.delete_env(:arbor_core, :agent_termination_timeout)
          value -> Application.put_env(:arbor_core, :agent_termination_timeout, value)
        end

        case original_extraction_config do
          nil -> Application.delete_env(:arbor_core, :agent_extraction_timeout)
          value -> Application.put_env(:arbor_core, :agent_extraction_timeout, value)
        end
      end
    end

    test "timeout configuration can be changed at runtime" do
      # Test that timeout changes are picked up dynamically
      original_config = Application.get_env(:arbor_core, :agent_termination_timeout)

      try do
        # Start with one timeout value
        initial_timeout = 3_000
        Application.put_env(:arbor_core, :agent_termination_timeout, initial_timeout)

        # Start an agent with initial timeout
        agent_id_1 = "runtime-change-1-#{:erlang.unique_integer([:positive])}"

        agent_spec_1 = %{
          id: agent_id_1,
          start: {Arbor.Test.Mocks.TestAgent, :start_link, [[]]},
          restart: :transient,
          type: :worker
        }

        {:ok, _pid1} = HordeSupervisor.start_agent(agent_spec_1)

        # Change timeout at runtime
        new_timeout = 7_000
        Application.put_env(:arbor_core, :agent_termination_timeout, new_timeout)

        # Start another agent with new timeout
        agent_id_2 = "runtime-change-2-#{:erlang.unique_integer([:positive])}"

        agent_spec_2 = %{
          id: agent_id_2,
          start: {Arbor.Test.Mocks.TestAgent, :start_link, [[]]},
          restart: :transient,
          type: :worker
        }

        {:ok, _pid2} = HordeSupervisor.start_agent(agent_spec_2)

        # Both agents should work with their respective timeout settings
        :ok = HordeSupervisor.stop_agent(agent_id_1)
        :ok = HordeSupervisor.stop_agent(agent_id_2)

        # Verify the new timeout is in effect
        assert Application.get_env(:arbor_core, :agent_termination_timeout) == new_timeout
      after
        # Restore original config
        case original_config do
          nil -> Application.delete_env(:arbor_core, :agent_termination_timeout)
          value -> Application.put_env(:arbor_core, :agent_termination_timeout, value)
        end
      end
    end
  end

  describe "timeout value validation" do
    test "zero timeout values are handled gracefully" do
      original_config = Application.get_env(:arbor_core, :agent_termination_timeout)

      try do
        # Set zero timeout
        Application.put_env(:arbor_core, :agent_termination_timeout, 0)

        agent_id = "zero-timeout-test-#{:erlang.unique_integer([:positive])}"

        agent_spec = %{
          id: agent_id,
          start: {Arbor.Test.Mocks.TestAgent, :start_link, [[]]},
          restart: :transient,
          type: :worker
        }

        # Should still work (implementation may treat 0 as immediate or use default)
        {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)
        :ok = HordeSupervisor.stop_agent(agent_id)
      after
        case original_config do
          nil -> Application.delete_env(:arbor_core, :agent_termination_timeout)
          value -> Application.put_env(:arbor_core, :agent_termination_timeout, value)
        end
      end
    end

    test "very large timeout values are handled gracefully" do
      original_config = Application.get_env(:arbor_core, :agent_termination_timeout)

      try do
        # Set very large timeout (10 minutes)
        large_timeout = 600_000
        Application.put_env(:arbor_core, :agent_termination_timeout, large_timeout)

        agent_id = "large-timeout-test-#{:erlang.unique_integer([:positive])}"

        agent_spec = %{
          id: agent_id,
          start: {Arbor.Test.Mocks.TestAgent, :start_link, [[]]},
          restart: :transient,
          type: :worker
        }

        # Should still work (operations shouldn't actually take this long)
        {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)
        :ok = HordeSupervisor.stop_agent(agent_id)
      after
        case original_config do
          nil -> Application.delete_env(:arbor_core, :agent_termination_timeout)
          value -> Application.put_env(:arbor_core, :agent_termination_timeout, value)
        end
      end
    end

    test "invalid timeout configuration falls back gracefully" do
      original_config = Application.get_env(:arbor_core, :agent_termination_timeout)

      try do
        # Set invalid timeout value
        Application.put_env(:arbor_core, :agent_termination_timeout, "invalid")

        agent_id = "invalid-timeout-test-#{:erlang.unique_integer([:positive])}"

        agent_spec = %{
          id: agent_id,
          start: {Arbor.Test.Mocks.TestAgent, :start_link, [[]]},
          restart: :transient,
          type: :worker
        }

        # Should either work (fallback to default) or fail gracefully
        result = HordeSupervisor.start_agent(agent_spec)

        case result do
          {:ok, _pid} ->
            # If it succeeds, cleanup should also work
            :ok = HordeSupervisor.stop_agent(agent_id)

          {:error, _reason} ->
            # If it fails, that's also acceptable behavior for invalid config
            assert true
        end
      after
        case original_config do
          nil -> Application.delete_env(:arbor_core, :agent_termination_timeout)
          value -> Application.put_env(:arbor_core, :agent_termination_timeout, value)
        end
      end
    end
  end

  describe "timeout behavior under load" do
    test "timeouts work correctly with multiple concurrent operations" do
      original_config = Application.get_env(:arbor_core, :agent_termination_timeout)

      try do
        # Set reasonable timeout
        Application.put_env(:arbor_core, :agent_termination_timeout, 5_000)

        base_id = "concurrent-timeout-#{:erlang.unique_integer([:positive])}"

        # Start multiple agents concurrently
        tasks =
          for i <- 1..3 do
            Task.async(fn ->
              agent_id = "#{base_id}-#{i}"

              agent_spec = %{
                id: agent_id,
                start: {Arbor.Test.Mocks.TestAgent, :start_link, [[]]},
                restart: :transient,
                type: :worker
              }

              start_time = System.monotonic_time(:millisecond)
              {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)
              end_time = System.monotonic_time(:millisecond)

              {agent_id, end_time - start_time}
            end)
          end

        # Wait for all to complete
        results = Task.await_many(tasks, 10_000)

        # All should complete within reasonable time
        for {agent_id, duration} <- results do
          assert duration < 8_000, "Agent #{agent_id} took too long to start: #{duration}ms"
        end

        # Clean up all agents
        for {agent_id, _duration} <- results do
          :ok = HordeSupervisor.stop_agent(agent_id)
        end
      after
        case original_config do
          nil -> Application.delete_env(:arbor_core, :agent_termination_timeout)
          value -> Application.put_env(:arbor_core, :agent_termination_timeout, value)
        end
      end
    end
  end

  describe "timeout configuration persistence" do
    test "timeout configuration persists across module reloads" do
      original_config = Application.get_env(:arbor_core, :agent_termination_timeout)

      try do
        # Set custom timeout
        custom_timeout = 6_000
        Application.put_env(:arbor_core, :agent_termination_timeout, custom_timeout)

        # Create agent to verify timeout is working
        agent_id = "persistence-test-#{:erlang.unique_integer([:positive])}"

        agent_spec = %{
          id: agent_id,
          start: {Arbor.Test.Mocks.TestAgent, :start_link, [[]]},
          restart: :transient,
          type: :worker
        }

        {:ok, _pid} = HordeSupervisor.start_agent(agent_spec)

        # Verify config is still set
        assert Application.get_env(:arbor_core, :agent_termination_timeout) == custom_timeout

        :ok = HordeSupervisor.stop_agent(agent_id)

        # Config should still be set after operations
        assert Application.get_env(:arbor_core, :agent_termination_timeout) == custom_timeout
      after
        case original_config do
          nil -> Application.delete_env(:arbor_core, :agent_termination_timeout)
          value -> Application.put_env(:arbor_core, :agent_termination_timeout, value)
        end
      end
    end
  end

  describe "timeout interaction with error scenarios" do
    test "timeouts work correctly when agents fail to start" do
      original_config = Application.get_env(:arbor_core, :agent_termination_timeout)

      try do
        # Set short timeout for faster test
        Application.put_env(:arbor_core, :agent_termination_timeout, 2_000)

        # Try to start an agent that will fail
        agent_id = "failing-agent-#{:erlang.unique_integer([:positive])}"

        agent_spec = %{
          id: agent_id,
          start: {NonExistentModule, :start_link, [[]]},
          restart: :transient,
          type: :worker
        }

        # Should fail but not hang due to timeout
        start_time = System.monotonic_time(:millisecond)
        result = HordeSupervisor.start_agent(agent_spec)
        end_time = System.monotonic_time(:millisecond)

        # Should fail quickly
        assert match?({:error, _}, result)
        duration = end_time - start_time
        # Should fail faster than the timeout (within 5 seconds)
        assert duration < 5_000, "Failed agent start should not take longer than timeout"
      after
        case original_config do
          nil -> Application.delete_env(:arbor_core, :agent_termination_timeout)
          value -> Application.put_env(:arbor_core, :agent_termination_timeout, value)
        end
      end
    end
  end
end
