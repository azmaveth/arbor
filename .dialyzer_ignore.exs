# Dialyzer ignore file - for dependencies and patterns only
# Project code (lib/, apps/) should use inline @dialyzer attributes

[
  # Dependencies and external modules can't use inline suppressions
  # Add any deps/ warnings here as they occur
  
  # Regex patterns for warnings that can't be easily suppressed inline
  
  # AgentBehavior defensive patterns that are unreachable in some implementations
  # NOTE: These warnings appear but may be accepted as defensive programming
  ~r/handle_restore_result.*is never used/,
  ~r/handle_restore_result.*pattern.*match/,
  
  # WebSockEx dependency issue - external library
  ~r/websockex\.ex.*no_return/,
  
  # OTP :cpu_sup module - optional dependency that may not be available
  ~r/cpu_sup/
]