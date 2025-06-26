defmodule Arbor.Agents.CodeAnalyzerTest do
  use ExUnit.Case, async: false

  alias Arbor.Agents.CodeAnalyzer
  alias Arbor.Core.HordeSupervisor
  alias Arbor.Test.Support.AsyncHelpers

  @moduletag :integration

  @temp_dir "/tmp/arbor_test_#{System.unique_integer([:positive])}"
  # Use hardcoded names as expected by HordeSupervisor
  @registry_name Arbor.Core.HordeAgentRegistry
  @supervisor_name Arbor.Core.HordeAgentSupervisor

  setup_all do
    # Start distributed Erlang if not already started
    case :net_kernel.start([:arbor_code_analyzer_test@localhost, :shortnames]) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        IO.puts("Warning: Could not start distributed Erlang: #{inspect(reason)}")
        :ok
    end

    # Configure for Horde mode
    Application.put_env(:arbor_core, :registry_impl, :horde)
    Application.put_env(:arbor_core, :supervisor_impl, :horde)

    # Ensure required infrastructure is running
    ensure_horde_infrastructure()

    # Wait for Horde to stabilize after setup, especially in CI
    AsyncHelpers.wait_until(
      fn ->
        # Verify all required processes are running and responsive
        registry_running = Process.whereis(@registry_name) != nil
        supervisor_running = Process.whereis(@supervisor_name) != nil

        registry_running and supervisor_running
      end,
      timeout: 1000,
      initial_delay: 50
    )

    :ok
  end

  setup do
    # Clean up any previous registrations
    cleanup_test_agents()

    # Create temporary directory for testing
    File.mkdir_p!(@temp_dir)

    # Create test files
    test_file = Path.join(@temp_dir, "test.ex")

    File.write!(test_file, """
    defmodule Test do
      # This is a comment
      def hello do
        if true do
          "world"
        else
          "goodbye"
        end
      end

      def complex_function(x) do
        case x do
          1 -> "one"
          2 -> "two"
          _ -> "other"
        end
      end
    end
    """)

    test_py_file = Path.join(@temp_dir, "test.py")

    File.write!(test_py_file, """
    def hello():
        # This is a comment
        if True:
            return "world"
        else
            return "goodbye"
    """)

    # Create subdirectory with file
    subdir = Path.join(@temp_dir, "subdir")
    File.mkdir_p!(subdir)
    File.write!(Path.join(subdir, "nested.ex"), "defmodule Nested, do: nil")

    on_exit(fn ->
      File.rm_rf!(@temp_dir)
    end)

    %{temp_dir: @temp_dir}
  end

  describe "agent lifecycle" do
    test "starts agent with valid arguments", %{temp_dir: temp_dir} do
      agent_id = "test_analyzer_#{:erlang.unique_integer([:positive, :monotonic])}"

      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir]
      }

      assert {:ok, pid} = HordeSupervisor.start_agent(agent_spec)
      assert Process.alive?(pid)

      # Clean up
      assert :ok = HordeSupervisor.stop_agent(agent_id)
    end

    test "fails with invalid working directory" do
      agent_id = "test_analyzer_#{:erlang.unique_integer([:positive, :monotonic])}"

      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: "/etc"]
      }

      # The agent's init will fail, causing start_link to fail, causing start_child to fail.
      # The error will propagate up from HordeSupervisor.start_agent.
      assert {:error, _reason} = HordeSupervisor.start_agent(agent_spec)

      # The agent process fails to start, but the spec is left in the registry.
      # stop_agent is designed to clean this up, even if the agent isn't running.
      assert :ok = HordeSupervisor.stop_agent(agent_id)

      # Verify that the agent spec is gone.
      assert {:error, :not_found} = HordeSupervisor.get_agent_info(agent_id)
    end
  end

  describe "analyze_file/2" do
    setup %{temp_dir: temp_dir} do
      agent_id = "analyzer_#{:erlang.unique_integer([:positive, :monotonic])}"

      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir]
      }

      {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      on_exit(fn -> HordeSupervisor.stop_agent(agent_id) end)

      %{agent_id: agent_id, pid: pid}
    end

    test "analyzes Elixir file correctly", %{agent_id: agent_id} do
      assert {:ok, analysis} = CodeAnalyzer.analyze_file(agent_id, "test.ex")

      assert analysis.language == "elixir"
      assert analysis.lines.total > 0
      assert analysis.lines.code > 0
      assert analysis.lines.comments > 0
      assert analysis.complexity.cyclomatic > 1
      assert is_integer(analysis.size_bytes)
      assert analysis.size_bytes > 0
    end

    test "analyzes Python file correctly", %{agent_id: agent_id} do
      assert {:ok, analysis} = CodeAnalyzer.analyze_file(agent_id, "test.py")

      assert analysis.language == "python"
      assert analysis.lines.total > 0
      assert analysis.lines.code > 0
      assert analysis.complexity.cyclomatic > 1
    end

    test "rejects path traversal attempts", %{agent_id: agent_id} do
      assert {:error, :path_traversal_detected} =
               CodeAnalyzer.analyze_file(agent_id, "../etc/passwd")
    end

    test "rejects files outside working directory", %{agent_id: agent_id} do
      assert {:error, :path_outside_working_dir} =
               CodeAnalyzer.analyze_file(agent_id, "/etc/passwd")
    end

    test "handles non-existent files", %{agent_id: agent_id} do
      assert {:error, :file_not_found} =
               CodeAnalyzer.analyze_file(agent_id, "nonexistent.ex")
    end
  end

  describe "analyze_directory/2" do
    setup %{temp_dir: temp_dir} do
      agent_id = "analyzer_#{:erlang.unique_integer([:positive, :monotonic])}"

      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir]
      }

      {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      on_exit(fn -> HordeSupervisor.stop_agent(agent_id) end)

      %{agent_id: agent_id, pid: pid}
    end

    test "analyzes directory with multiple files", %{agent_id: agent_id} do
      assert {:ok, analysis} = CodeAnalyzer.analyze_directory(agent_id, ".")

      # test.ex and test.py
      assert analysis.files_count >= 2
      assert analysis.total_lines > 0
      assert analysis.total_size > 0
      assert "elixir" in analysis.languages
      assert "python" in analysis.languages
      assert is_list(analysis.files)
    end

    test "handles empty directories", %{agent_id: agent_id, temp_dir: temp_dir} do
      empty_dir = Path.join(temp_dir, "empty")
      File.mkdir_p!(empty_dir)

      assert {:ok, analysis} = CodeAnalyzer.analyze_directory(agent_id, "empty")
      assert analysis.files_count == 0
      assert analysis.total_lines == 0
    end
  end

  describe "list_files/2" do
    setup %{temp_dir: temp_dir} do
      agent_id = "analyzer_#{:erlang.unique_integer([:positive, :monotonic])}"

      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir]
      }

      {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      on_exit(fn -> HordeSupervisor.stop_agent(agent_id) end)

      %{agent_id: agent_id, pid: pid}
    end

    test "lists files in directory", %{agent_id: agent_id} do
      assert {:ok, files} = CodeAnalyzer.list_files(agent_id, ".")

      file_names = Enum.map(files, & &1.name)
      assert "test.ex" in file_names
      assert "test.py" in file_names
      assert "subdir" in file_names

      # Check file info structure
      test_file = Enum.find(files, &(&1.name == "test.ex"))
      assert test_file.type == :file
      assert is_integer(test_file.size)
      assert test_file.size > 0
    end

    test "lists files in subdirectory", %{agent_id: agent_id} do
      assert {:ok, files} = CodeAnalyzer.list_files(agent_id, "subdir")

      file_names = Enum.map(files, & &1.name)
      assert "nested.ex" in file_names
    end
  end

  describe "exec/3" do
    setup %{temp_dir: temp_dir} do
      agent_id = "analyzer_#{:erlang.unique_integer([:positive, :monotonic])}"

      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir]
      }

      {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      on_exit(fn -> HordeSupervisor.stop_agent(agent_id) end)

      %{agent_id: agent_id, pid: pid}
    end

    test "executes analyze command on file", %{agent_id: agent_id} do
      assert {:ok, analysis} = CodeAnalyzer.exec(agent_id, "analyze", ["test.ex"])

      assert analysis.language == "elixir"
      assert analysis.lines.total > 0
    end

    test "executes analyze command on directory", %{agent_id: agent_id} do
      assert {:ok, analysis} = CodeAnalyzer.exec(agent_id, "analyze", ["."])

      assert analysis.files_count > 0
      assert is_list(analysis.languages)
    end

    test "executes list command", %{agent_id: agent_id} do
      assert {:ok, files} = CodeAnalyzer.exec(agent_id, "list", [])

      assert is_list(files)
      file_names = Enum.map(files, & &1.name)
      assert "test.ex" in file_names
    end

    test "executes status command", %{agent_id: agent_id} do
      assert {:ok, status} = CodeAnalyzer.exec(agent_id, "status", [])

      assert status.agent_id == agent_id
      assert is_integer(status.analysis_count)
    end

    test "rejects invalid commands", %{agent_id: agent_id} do
      assert {:error, :command_not_allowed} =
               CodeAnalyzer.exec(agent_id, "rm", ["-rf", "/"])
    end

    test "rejects invalid arguments", %{agent_id: agent_id} do
      assert {:error, :invalid_args_for_analyze} =
               CodeAnalyzer.exec(agent_id, "analyze", [])

      assert {:error, :invalid_args_for_list} =
               CodeAnalyzer.exec(agent_id, "list", ["too", "many", "args"])
    end
  end

  describe "state management" do
    setup %{temp_dir: temp_dir} do
      agent_id = "analyzer_#{:erlang.unique_integer([:positive, :monotonic])}"

      agent_spec = %{
        id: agent_id,
        module: CodeAnalyzer,
        args: [agent_id: agent_id, working_dir: temp_dir]
      }

      {:ok, pid} = HordeSupervisor.start_agent(agent_spec)

      on_exit(fn -> HordeSupervisor.stop_agent(agent_id) end)

      %{agent_id: agent_id, pid: pid}
    end

    test "tracks analysis count", %{agent_id: agent_id, pid: pid} do
      # Initial state
      initial_state = GenServer.call(pid, :get_state)
      assert initial_state.analysis_count == 0

      # Perform analysis
      assert {:ok, _} = CodeAnalyzer.analyze_file(agent_id, "test.ex")

      # Check updated state
      updated_state = GenServer.call(pid, :get_state)
      assert updated_state.analysis_count == 1
      assert updated_state.last_analysis != nil
    end

    test "extract_state returns serializable state", %{pid: pid} do
      assert {:ok, state} = GenServer.call(pid, :extract_state)

      # State should be serializable (no PIDs, refs, etc.)
      assert is_map(state)
      assert Map.has_key?(state, :agent_id)
      assert Map.has_key?(state, :working_dir)
      assert Map.has_key?(state, :analysis_count)
    end
  end

  # Helper functions

  defp ensure_horde_infrastructure do
    IO.puts("Ensuring Horde infrastructure is running for test...")
    IO.puts("  -> Using Registry: #{inspect(@registry_name)}")
    IO.puts("  -> Using Supervisor: #{inspect(@supervisor_name)}")
    IO.puts("  -> Using HordeSupervisor: #{inspect(Arbor.Core.HordeSupervisor)}")

    # Start HordeSupervisor infrastructure if not running.
    if Process.whereis(Arbor.Core.HordeSupervisorSupervisor) == nil do
      HordeSupervisor.start_supervisor()
    end

    # Set members for single-node test environment
    Horde.Cluster.set_members(@registry_name, [{@registry_name, node()}])
    Horde.Cluster.set_members(@supervisor_name, [{@supervisor_name, node()}])

    # Wait for Horde components to stabilize
    IO.puts("  -> Waiting for Horde membership to be ready...")
    wait_for_membership_ready()

    # Verify infrastructure is ready
    registry_ready = Process.whereis(@registry_name) != nil
    supervisor_ready = Process.whereis(@supervisor_name) != nil
    horde_supervisor_ready = Process.whereis(Arbor.Core.HordeSupervisorSupervisor) != nil

    unless registry_ready and supervisor_ready and horde_supervisor_ready do
      Logger.error("Horde infrastructure not available",
        registry_status: %{name: @registry_name, pid: Process.whereis(@registry_name)},
        supervisor_status: %{name: @supervisor_name, pid: Process.whereis(@supervisor_name)},
        horde_supervisor_status: %{
          name: Arbor.Core.HordeSupervisorSupervisor,
          pid: Process.whereis(Arbor.Core.HordeSupervisorSupervisor)
        }
      )

      raise "Horde infrastructure not available. Ensure the application is started properly."
    end

    IO.puts("Horde infrastructure is ready.")
    :ok
  end

  defp wait_for_membership_ready(timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_membership_loop(deadline)
  end

  defp wait_for_membership_loop(deadline) do
    now = System.monotonic_time(:millisecond)

    if now > deadline do
      registry_members = Horde.Cluster.members(@registry_name)
      supervisor_members = Horde.Cluster.members(@supervisor_name)

      raise """
      Timed out waiting for Horde membership synchronization.
      - Current Node: #{inspect(node())}
      - Registry Members: #{inspect(registry_members)}
      - Supervisor Members: #{inspect(supervisor_members)}
      """
    else
      registry_members = Horde.Cluster.members(@registry_name)
      supervisor_members = Horde.Cluster.members(@supervisor_name)
      current_node = node()

      # Check for proper named members in the new format
      expected_registry_member = {@registry_name, current_node}
      expected_supervisor_member = {@supervisor_name, current_node}

      registry_ready =
        expected_registry_member in registry_members or
          {expected_registry_member, expected_registry_member} in registry_members

      supervisor_ready =
        expected_supervisor_member in supervisor_members or
          {expected_supervisor_member, expected_supervisor_member} in supervisor_members

      if registry_ready and supervisor_ready do
        IO.puts("  -> Horde membership is ready.")
        # Additional stabilization wait for distributed supervisor CRDT sync
        AsyncHelpers.wait_until(
          fn ->
            case Horde.DynamicSupervisor.which_children(@supervisor_name) do
              [] ->
                true

              children ->
                # Accept any tracked children count
                length(children) >= 0
            end
          end,
          timeout: 1000,
          initial_delay: 50
        )

        :ok
      else
        Process.sleep(100)
        wait_for_membership_loop(deadline)
      end
    end
  end

  defp cleanup_test_agents do
    IO.puts("\n--- Starting comprehensive Horde cleanup for test ---")

    try do
      case HordeSupervisor.list_agents() do
        {:ok, agents} ->
          process_agents_cleanup(agents)

        {:error, reason} ->
          IO.puts(
            "  -> ERROR: Failed to list agents during cleanup: #{inspect(reason)}. State may be inconsistent."
          )
      end
    rescue
      exception ->
        handle_cleanup_exception(exception)
    end

    IO.puts("--- Horde cleanup finished ---\n")
  end

  defp process_agents_cleanup(agents) do
    running_agents = Enum.filter(agents, &(&1.status == :running))
    agent_ids_to_stop = Enum.map(agents, & &1.id)

    monitors = monitor_running_agents(running_agents)
    stop_agents_if_any(agent_ids_to_stop)
    wait_for_monitored_processes(monitors)
    wait_for_distributed_sync()
    verify_cleanup_complete()
  end

  defp monitor_running_agents(running_agents) do
    if Enum.any?(running_agents) do
      pids_to_monitor = Enum.map(running_agents, & &1.pid)
      IO.puts("  -> Monitoring #{length(pids_to_monitor)} running processes.")
      Enum.map(pids_to_monitor, &Process.monitor/1)
    else
      []
    end
  end

  defp stop_agents_if_any(agent_ids_to_stop) do
    if Enum.any?(agent_ids_to_stop) do
      IO.puts("  -> Stopping #{length(agent_ids_to_stop)} agents (running and specs)...")
      Enum.each(agent_ids_to_stop, &HordeSupervisor.stop_agent/1)
    else
      IO.puts("  -> No agents or specs to clean up.")
    end
  end

  defp wait_for_monitored_processes(monitors) do
    if Enum.any?(monitors) do
      IO.puts("  -> Waiting for processes to terminate (max 3s)...")
      wait_for_processes_down(monitors, 3000)
    end
  end

  defp wait_for_distributed_sync do
    # Wait for distributed state to sync
    AsyncHelpers.wait_until(
      fn ->
        # Just wait for CRDT sync time
        Process.sleep(200)
        true
      end,
      timeout: 300,
      initial_delay: 200
    )
  end

  defp verify_cleanup_complete do
    IO.puts("  -> Verifying cleanup...")

    case HordeSupervisor.list_agents() do
      {:ok, []} ->
        IO.puts("    -> OK: All agents stopped and unregistered.")

      {:ok, remaining_agents} ->
        IO.puts("    -> WARNING: #{length(remaining_agents)} remain after cleanup.")
        Logger.warning("Remaining agents after cleanup", remaining_agents: remaining_agents)

      {:error, reason} ->
        IO.puts(
          "    -> WARNING: Could not verify cleanup, list_agents failed: #{inspect(reason)}"
        )
    end
  end

  defp handle_cleanup_exception(exception) do
    IO.puts(
      "  -> ERROR: Exception during cleanup: #{inspect(exception)}. State may be inconsistent for next test."
    )

    Logger.error("Cleanup exception details", exception: inspect(exception))
  end

  defp wait_for_processes_down(monitors, timeout) do
    target_time = System.monotonic_time(:millisecond) + timeout
    wait_loop(monitors, target_time)
  end

  defp wait_loop([], _target_time) do
    IO.puts("    -> OK: All monitored processes terminated.")
  end

  defp wait_loop(monitors, target_time) do
    remaining_time = max(0, target_time - System.monotonic_time(:millisecond))

    receive do
      {:DOWN, ref, _, _, _} ->
        # A process went down. See if it's one we are monitoring.
        remaining_monitors = List.delete(monitors, ref)
        wait_loop(remaining_monitors, target_time)
    after
      remaining_time ->
        # Timeout occurred. Check if we're still waiting for monitors.
        unless Enum.empty?(monitors) do
          IO.puts(
            "    -> WARNING: Timed out waiting for #{length(monitors)} processes to terminate."
          )

          Enum.each(monitors, &Process.demonitor(&1, [:flush]))
        end
    end
  end
end
