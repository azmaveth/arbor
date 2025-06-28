[
  # TestSuiteAnalyzer is only available in test environment
  {"lib/mix/tasks/test.analyze.ex", :call, 214},
  {"lib/mix/tasks/test.analyze.ex", :call, 231},
  
  # AgentBehavior generates defensive error handling that becomes unreachable
  {"lib/arbor/agents/code_analyzer.ex", :pattern_match_cov},
  {"lib/arbor/core/stateful_example_agent.ex", :pattern_match_cov},
  
  # :cpu_sup is an optional dependency (part of :os_mon)
  {"lib/arbor/core/cluster_manager.ex", :call, 771},
  
  # Legacy checkpoint functions handle error cases even though our implementation never fails
  {"lib/arbor/core/stateful_example_agent.ex", :pattern_match, 226},
  {"lib/arbor/core/stateful_example_agent.ex", :pattern_match, 234},
  
  # Gateway uses String.t() execution IDs instead of reference() for distributed compatibility
  {"lib/arbor/core/gateway.ex", :callback_spec_arg_type_mismatch},
  
  # Mix tasks use Mix.shell/0 and Mix.Task.run/1 which aren't available during static analysis
  {"lib/mix/tasks/arbor.gen.impl.ex", :call},
  {"lib/mix/tasks/credo.refactor.ex", :call}
]