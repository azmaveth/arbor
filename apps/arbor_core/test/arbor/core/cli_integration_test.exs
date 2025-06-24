defmodule Arbor.Core.CliIntegrationTest do
  use ExUnit.Case, async: false

  # Skip due to intermittent circular dependency issues in CI
  @moduletag :skip
  @moduletag :integration
  @moduletag timeout: 30_000

  alias Arbor.Core.Gateway
  alias ArborCli.Commands.Agent
  alias Arbor.Test.Support.AsyncHelpers

  setup_all do
    # Configure application environment for integration testing with Horde.
    # Setting :env to :test ensures the Application starts the necessary components.
    Application.put_env(:arbor_core, :registry_impl, :horde)
    Application.put_env(:arbor_core, :supervisor_impl, :horde)
    Application.put_env(:arbor_core, :coordinator_impl, :horde)
    Application.put_env(:arbor_core, :env, :test)
    Application.put_env(:arbor_core, :http_api, enabled: true)

    # Start required dependencies first (handle already started)
    case start_supervised({Phoenix.PubSub, name: Arbor.Core.PubSub}) do
      {:ok, _pubsub} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Start the HordeAgentRegistry manually for CLI integration tests
    case start_supervised(
           {Horde.Registry,
            [
              name: Arbor.Core.HordeAgentRegistry,
              keys: :unique,
              members: :auto,
              delta_crdt_options: [sync_interval: 100]
            ]}
         ) do
      {:ok, _registry} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Start the SessionRegistry manually for CLI integration tests
    case start_supervised(
           {Horde.Registry,
            [
              name: Arbor.Core.SessionRegistry,
              keys: :unique,
              members: :auto,
              delta_crdt_options: [sync_interval: 100]
            ]}
         ) do
      {:ok, _registry} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Start the HordeAgentSupervisor manually for CLI integration tests
    case start_supervised(
           {Horde.DynamicSupervisor,
            [
              name: Arbor.Core.HordeAgentSupervisor,
              strategy: :one_for_one,
              members: :auto,
              delta_crdt_options: [sync_interval: 100]
            ]}
         ) do
      {:ok, _supervisor} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Start the HordeSupervisor GenServer for registration
    case start_supervised({Arbor.Core.HordeSupervisor, []}) do
      {:ok, _horde_supervisor} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Start the Sessions Manager
    case start_supervised(Arbor.Core.Sessions.Manager) do
      {:ok, _sessions} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Start the Gateway
    case start_supervised(Arbor.Core.Gateway) do
      {:ok, _gateway} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Wait for components started by the Application to sync
    AsyncHelpers.wait_until(
      fn ->
        # Verify core components are running
        gateway_running = Process.whereis(Arbor.Core.Gateway) != nil
        registry_running = Process.whereis(Arbor.Core.HordeAgentRegistry) != nil
        supervisor_running = Process.whereis(Arbor.Core.HordeAgentSupervisor) != nil

        gateway_running and registry_running and supervisor_running
      end,
      timeout: 2000,
      initial_delay: 200
    )

    on_exit(fn ->
      # Reset application environment to default
      Application.put_env(:arbor_core, :registry_impl, :auto)
      Application.put_env(:arbor_core, :supervisor_impl, :auto)
      Application.put_env(:arbor_core, :coordinator_impl, :auto)
      Application.put_env(:arbor_core, :http_api, enabled: false)
    end)

    :ok
  end

  setup do
    # Clean up any existing agents from previous tests
    # First, clean up via supervisor
    case Horde.DynamicSupervisor.which_children(Arbor.Core.HordeAgentSupervisor) do
      children when is_list(children) ->
        Enum.each(children, fn
          {_, pid, _, _} when is_pid(pid) ->
            Horde.DynamicSupervisor.terminate_child(Arbor.Core.HordeAgentSupervisor, pid)

          _ ->
            :ok
        end)

      _ ->
        :ok
    end

    # Force clean all registry entries directly
    # Get all entries from Horde.Registry (including agent specs)
    entries =
      Horde.Registry.select(Arbor.Core.HordeAgentRegistry, [
        {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])

    Enum.each(entries, fn {key, _pid, _value} ->
      Horde.Registry.unregister(Arbor.Core.HordeAgentRegistry, key)
    end)

    # Also use HordeSupervisor.stop_agent for proper cleanup of any running agents
    case Arbor.Core.HordeSupervisor.list_agents() do
      {:ok, agents} ->
        Enum.each(agents, fn agent ->
          Arbor.Core.HordeSupervisor.stop_agent(agent.id)
        end)

      _ ->
        :ok
    end

    # Wait for async cleanup to complete
    AsyncHelpers.wait_until(
      fn ->
        # Verify no agents remain
        case Arbor.Core.HordeSupervisor.list_agents() do
          {:ok, []} -> true
          _ -> false
        end
      end,
      timeout: 1000,
      initial_delay: 100
    )

    :ok
  end

  describe "CLI to Agent Steel Thread" do
    @tag :integration
    test "validates complete CLI to agent steel thread" do
      # Use a UUID to ensure uniqueness
      agent_id = "cli-test-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      agent_type = :code_analyzer

      # 1. Spawn an agent via the CLI command module. This travels through the Gateway.
      spawn_opts = %{name: agent_id}

      assert {:ok, spawn_result} = Agent.execute(:spawn, [agent_type], spawn_opts)

      assert %{
               action: "spawn",
               result: %{status: :completed, result: %{data: result_data}}
             } = spawn_result

      assert result_data.agent_id == agent_id
      assert result_data.status == :active

      # Wait for the agent to register across the cluster
      AsyncHelpers.wait_until(
        fn ->
          case Arbor.Core.HordeSupervisor.get_agent_info(agent_id) do
            {:ok, info} -> info.status == :active
            _ -> false
          end
        end,
        timeout: 1000,
        initial_delay: 100
      )

      # 2. Get the agent's status via the CLI.
      assert {:ok, status_result} = Agent.execute(:status, [agent_id], %{})

      assert %{
               action: "status",
               result: %{
                 status: :completed,
                 result: %{data: %{agents: [%{agent_id: ^agent_id, status: :active}]}}
               }
             } = status_result

      # 3. Execute a command on the agent via the CLI.
      command = "ping"
      args = ["arg1", "arg2"]
      assert {:ok, exec_result} = Agent.execute(:exec, [agent_id, command | args], %{})

      assert %{
               action: "exec",
               result: %{status: :completed, result: %{data: exec_data}}
             } = exec_result

      assert exec_data.agent_id == agent_id
      assert exec_data.command == command
      # This assertion confirms that a result was received from the agent execution.
      assert exec_data.result != nil
    end

    test "validates contract enforcement on both sides" do
      # 1. Test invalid command rejection at the CLI level.
      # The `Command.validate/1` function inside the CLI command module should catch this.
      # The :type must be an atom, not a string.
      agent_type = :code_analyzer
      spawn_opts = %{name: "validation-agent-#{System.unique_integer([:positive])}"}

      assert {:error, {:invalid_command, {:invalid_type, :type, "expected is_atom"}}} =
               Agent.execute(:spawn, [Atom.to_string(agent_type)], spawn_opts)

      # 2. Test invalid command rejection at the Gateway level.
      # This proves the Gateway shares the same validation logic, providing defense-in-depth.
      invalid_status_command = %{
        type: :get_agent_status,
        # agent_id should be a string
        params: %{agent_id: 123}
      }

      # Create a session to get a valid context for the Gateway call.
      {:ok, %{session_id: session_id}} = ArborCli.GatewayClient.create_session()
      context = %{session_id: session_id}

      assert {:error, {:invalid_type, :agent_id, "expected is_binary"}} =
               Gateway.validate_command(invalid_status_command, context, nil)

      ArborCli.GatewayClient.end_session(session_id)
    end

    test "handles CLI command failures gracefully" do
      # 1. Test commands on a non-existent agent.
      non_existent_agent_id = "agent-that-does-not-exist"

      # A status check for a non-existent agent should succeed but return an empty list.
      assert {:ok, status_result} = Agent.execute(:status, [non_existent_agent_id], %{})

      assert %{
               action: "status",
               result: %{
                 status: :completed,
                 result: %{data: %{agents: [], total: 0}}
               }
             } = status_result

      assert {:error, {:exec_failed, {:error, :agent_not_found}}} =
               Agent.execute(:exec, [non_existent_agent_id, "some-command"], %{})

      # 2. Test invalid arguments at the CLI parsing level, before a command is even constructed.
      # `spawn` requires an agent type.
      assert {:error, {:invalid_args, "spawn requires exactly one argument (agent type)", []}} =
               Agent.execute(:spawn, [], %{})

      # `status` requires an agent ID.
      assert {:error, {:invalid_args, "status requires exactly one argument (agent ID)", []}} =
               Agent.execute(:status, [], %{})

      # `exec` requires at least an agent ID and a command.
      assert {:error,
              {:invalid_args, "exec requires at least two arguments (agent ID and command)",
               ["just_one_arg"]}} = Agent.execute(:exec, ["just_one_arg"], %{})
    end
  end
end
