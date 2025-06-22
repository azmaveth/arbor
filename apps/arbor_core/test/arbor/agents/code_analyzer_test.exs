defmodule Arbor.Agents.CodeAnalyzerTest do
  use ExUnit.Case, async: false

  alias Arbor.Agents.CodeAnalyzer
  alias Arbor.Core.HordeSupervisor

  @temp_dir "/tmp/arbor_test_#{System.unique_integer([:positive])}"
  @unique_id System.unique_integer([:positive])
  # Use hardcoded names as expected by HordeSupervisor
  @registry_name Arbor.Core.HordeAgentRegistry
  @supervisor_name Arbor.Core.HordeAgentSupervisor

  setup_all do
    # Configure for Horde mode
    Application.put_env(:arbor_core, :registry_impl, :horde)
    Application.put_env(:arbor_core, :supervisor_impl, :horde)

    # Start distributed Erlang if not already started
    node_name = :"arbor_codeanalyzer_test_#{@unique_id}@localhost"

    case :net_kernel.start([node_name, :shortnames]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} ->
        IO.puts("Warning: Could not start distributed Erlang: #{inspect(reason)}")
        :ok
    end

    # Ensure required infrastructure is running
    ensure_horde_infrastructure()

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
      agent_id = "test_analyzer_#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"

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
      agent_id = "test_analyzer_#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"

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
      agent_id = "analyzer_#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"

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
      agent_id = "analyzer_#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"

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

      assert analysis.files_count >= 2 # test.ex and test.py
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
      agent_id = "analyzer_#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"

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
      agent_id = "analyzer_#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"

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
      agent_id = "analyzer_#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"

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
      assert {:ok, initial_state} = GenServer.call(pid, :get_state)
      assert initial_state.analysis_count == 0

      # Perform analysis
      assert {:ok, _} = CodeAnalyzer.analyze_file(agent_id, "test.ex")

      # Check updated state
      assert {:ok, updated_state} = GenServer.call(pid, :get_state)
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

    # Start Horde.Registry if not running
    if Process.whereis(@registry_name) == nil do
      IO.puts("  -> Starting Horde.Registry...")
      start_supervised!(
        {Horde.Registry,
         [
           name: @registry_name,
           keys: :unique,
           members: :auto,
           delta_crdt_options: [sync_interval: 100]
         ]}
      )
      IO.puts("  -> Horde.Registry started.")
    else
      IO.puts("  -> Horde.Registry already running.")
    end

    # Start Horde.DynamicSupervisor if not running
    if Process.whereis(@supervisor_name) == nil do
      IO.puts("  -> Starting Horde.DynamicSupervisor...")
      start_supervised!(
        {Horde.DynamicSupervisor,
         [
           name: @supervisor_name,
           strategy: :one_for_one,
           distribution_strategy: Horde.UniformRandomDistribution,
           process_redistribution: :active,
           members: :auto,
           delta_crdt_options: [sync_interval: 100]
         ]}
      )
      IO.puts("  -> Horde.DynamicSupervisor started.")
    else
      IO.puts("  -> Horde.DynamicSupervisor already running.")
    end

    # Start HordeSupervisor GenServer if not running
    if Process.whereis(Arbor.Core.HordeSupervisor) == nil do
      IO.puts("  -> Starting Arbor.Core.HordeSupervisor...")
      start_supervised!(Arbor.Core.HordeSupervisor)
      IO.puts("  -> Arbor.Core.HordeSupervisor started.")
    else
      IO.puts("  -> Arbor.Core.HordeSupervisor already running.")
    end

    # Wait for Horde components to stabilize
    IO.puts("  -> Waiting for Horde components to stabilize...")
    :timer.sleep(300)

    # Verify infrastructure is ready
    registry_ready = Process.whereis(@registry_name) != nil
    supervisor_ready = Process.whereis(@supervisor_name) != nil
    horde_supervisor_ready = Process.whereis(Arbor.Core.HordeSupervisor) != nil

    unless registry_ready and supervisor_ready and horde_supervisor_ready do
      IO.inspect(
        %{
          "Horde Infrastructure Status" => "FAILED",
          "Registry" => %{name: @registry_name, pid: Process.whereis(@registry_name)},
          "Supervisor" => %{name: @supervisor_name, pid: Process.whereis(@supervisor_name)},
          "HordeSupervisor" => %{
            name: Arbor.Core.HordeSupervisor,
            pid: Process.whereis(Arbor.Core.HordeSupervisor)
          }
        },
        label: "Horde Infrastructure Check"
      )

      raise "Horde infrastructure failed to start properly. Check logs for details."
    end

    IO.puts("Horde infrastructure is ready.")
    :ok
  end

  defp cleanup_test_agents do
    IO.puts("\n--- Starting comprehensive Horde cleanup for test ---")

    try do
      case HordeSupervisor.list_agents() do
        {:ok, agents} ->
          running_agents = Enum.filter(agents, &(&1.status == :running))
          agent_ids_to_stop = Enum.map(agents, & &1.id)

          monitors =
            if Enum.any?(running_agents) do
              pids_to_monitor = Enum.map(running_agents, & &1.pid)
              IO.puts("  -> Monitoring #{length(pids_to_monitor)} running processes.")
              Enum.map(pids_to_monitor, &Process.monitor/1)
            else
              []
            end

          if Enum.any?(agent_ids_to_stop) do
            IO.puts("  -> Stopping #{length(agent_ids_to_stop)} agents (running and specs)...")
            Enum.each(agent_ids_to_stop, &HordeSupervisor.stop_agent/1)
          else
            IO.puts("  -> No agents or specs to clean up.")
          end

          if Enum.any?(monitors) do
            IO.puts("  -> Waiting for processes to terminate (max 3s)...")
            wait_for_processes_down(monitors, 3000)
          end

          # Verification step
          :timer.sleep(200) # Allow a moment for distributed state to sync
          IO.puts("  -> Verifying cleanup...")

          case HordeSupervisor.list_agents() do
            {:ok, []} ->
              IO.puts("    -> OK: All agents stopped and unregistered.")

            {:ok, remaining_agents} ->
              IO.puts(
                "    -> WARNING: #{length(remaining_agents)} agents remain after cleanup."
              )

              IO.inspect(remaining_agents, label: "Remaining agents")

            {:error, reason} ->
              IO.puts(
                "    -> WARNING: Could not verify cleanup, list_agents failed: #{inspect(reason)}"
              )
          end

        {:error, reason} ->
          IO.puts(
            "  -> ERROR: Failed to list agents during cleanup: #{inspect(reason)}. State may be inconsistent."
          )
      end
    rescue
      exception ->
        IO.puts(
          "  -> ERROR: Exception during cleanup: #{inspect(exception)}. State may be inconsistent for next test."
        )

        IO.inspect(Exception.format_stacktrace(__STACKTRACE__), label: "Cleanup Stacktrace")
    end

    IO.puts("--- Horde cleanup finished ---\n")
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
