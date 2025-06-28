
Logger.configure(level: :debug)

execution_result = Arbor.Core.Gateway.handle_command(
  :spawn_agent,
  %{
    agent_type: "CodeAnalyzer",
    agent_id: "debug_agent_with_logging",
    working_dir: "/tmp"
  }
)

IO.inspect(execution_result, label: "execution_result")

