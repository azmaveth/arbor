[
  # Mix tasks - these files use Mix.shell/0 and Mix.Task.run/1 which aren't available during static analysis
  {"apps/arbor_persistence/lib/mix/tasks/test.analyze.ex", :callback_info_missing},
  {"apps/arbor_persistence/lib/mix/tasks/test.analyze.ex", :unknown_function},
  {"lib/mix/tasks/arbor.gen.impl.ex", :callback_info_missing},
  {"lib/mix/tasks/test.analyze.ex", :callback_info_missing},
  {"lib/mix/tasks/test.analyze.ex", :unknown_function},

  # Agent behavior unused callbacks - these are optional callbacks that may not be used
  {"apps/arbor_core/lib/arbor/agents/code_analyzer.ex", :unused_fun},
  {"apps/arbor_core/lib/arbor/core/stateful_example_agent.ex", :unused_fun},

  # System dependencies that may not be available during static analysis
  {"apps/arbor_core/lib/arbor/core/cluster_manager.ex", :unknown_function}
]