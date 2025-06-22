# Arbor CLI Enhancement Plan

**Status**: PROPOSED  
**Created**: 2025-06-21  
**Objective**: Enhance Arbor CLI with rich terminal UI and advanced patterns from mcp_chat

## Executive Summary

This plan outlines enhancements to the Arbor CLI based on valuable patterns identified from the mcp_chat codebase. The enhancements focus on improving user experience through rich terminal UI, intelligent command handling, and real-time progress feedback for agent operations.

## Patterns Identified from mcp_chat

### 1. Rich Terminal UI (Owl Library)
- Colored output with semantic meaning
- Box layouts for structured content
- Table rendering for data display
- Progress bars for long operations
- Markdown rendering support

### 2. Command Router Pattern
- Centralized command dispatch
- Support for command aliases
- Intelligent command completions
- Graceful error handling with suggestions

### 3. Base Command Module Pattern
- Behavior definitions for consistency
- Shared utilities via __using__ macro
- Standardized messaging patterns
- Session context helpers

### 4. Helper Functions Library
- Time formatting ("X hours ago")
- File size formatting (KB/MB/GB)
- Number formatting with separators
- Key-value table displays
- Operation status indicators

### 5. Enhanced Agent Integration
- Real-time execution progress
- Event-based monitoring
- Dynamic command discovery
- Intelligent command suggestions

## Implementation Phases

### Phase 1: Foundational UI & Output Consistency
**Timeline**: 1-2 days  
**Goal**: Immediate visual improvements and consistent output

#### 1.1 Add Owl Library Dependency
```elixir
# In arbor_cli/mix.exs
defp deps do
  [
    {:owl, "~> 0.11"}
  ]
end
```

#### 1.2 Create Enhanced Renderer Module
```elixir
# arbor_cli/lib/arbor_cli/renderer_enhanced.ex
defmodule ArborCli.RendererEnhanced do
  import Owl.IO, only: [puts: 1]
  
  @colors %{
    agent: :cyan,
    success: :green,
    error: :red,
    warning: :yellow,
    info: :blue,
    progress: :magenta
  }
  
  # Rich formatting functions
  def show_agent_spawn(agent_info)
  def show_agent_status_table(agents)
  def show_execution_progress(progress, stage)
  def show_command_output_box(output)
end
```

#### 1.3 Add Formatted Output Helpers
```elixir
# arbor_cli/lib/arbor_cli/format_helpers.ex
defmodule ArborCli.FormatHelpers do
  def format_time_ago(datetime)
  def format_file_size(bytes)
  def format_number(number, style \\ :default)
  def format_duration(milliseconds)
  def format_agent_id(agent_id)
end
```

### Phase 2: Core Command Structure & Usability
**Timeline**: 2-3 days  
**Goal**: Improve developer experience and CLI usability

#### 2.1 Create Base Command Behavior
```elixir
# arbor_cli/lib/arbor_cli/command_base.ex
defmodule ArborCli.CommandBase do
  @callback execute(subcommand :: String.t(), args :: list(), options :: map()) :: 
    {:ok, any()} | {:error, any()}
  
  defmacro __using__(_opts) do
    quote do
      @behaviour ArborCli.CommandBase
      
      import ArborCli.RendererEnhanced
      import ArborCli.FormatHelpers
      
      # Common utilities
      def validate_args(args, required_count)
      def with_session(fun)
      def handle_result(result)
    end
  end
end
```

#### 2.2 Refactor Existing Commands
```elixir
# Update arbor_cli/lib/arbor_cli/commands/agent.ex
defmodule ArborCli.Commands.Agent do
  use ArborCli.CommandBase
  
  # Refactored with base behavior pattern
end
```

#### 2.3 Implement Command Suggestions
```elixir
# arbor_cli/lib/arbor_cli/command_suggester.ex
defmodule ArborCli.CommandSuggester do
  def suggest_commands(input, available_commands)
  def string_similarity(str1, str2)
end
```

### Phase 3: Advanced Agent Integration UI
**Timeline**: 2-3 days  
**Goal**: Rich real-time feedback for agent operations

#### 3.1 Event Stream Renderer
```elixir
# arbor_cli/lib/arbor_cli/event_stream_renderer.ex
defmodule ArborCli.EventStreamRenderer do
  def render_agent_events(event_stream)
  def show_progress_bar(progress, stage)
  def show_execution_timeline(events)
end
```

#### 3.2 Enhanced Agent Command Module
```elixir
# Update agent command to use rich UI
defmodule ArborCli.Commands.Agent do
  def execute("exec", [agent_id, command | args], options) do
    # Show real-time progress
    # Handle event streaming
    # Display rich results
  end
end
```

## Specific Implementation Tasks

### Phase 1 Tasks
- [ ] Add Owl dependency to mix.exs
- [ ] Create RendererEnhanced module with basic functions
- [ ] Implement FormatHelpers module
- [ ] Update existing Renderer calls to use enhanced version
- [ ] Add tests for formatting functions

### Phase 2 Tasks
- [ ] Define CommandBase behavior
- [ ] Create CommandBase.__using__ macro
- [ ] Refactor Agent command to use base
- [ ] Implement CommandSuggester module
- [ ] Update CLI router to use suggestions
- [ ] Add command suggestion tests

### Phase 3 Tasks
- [ ] Create EventStreamRenderer module
- [ ] Integrate with Gateway event streaming
- [ ] Add progress bar rendering
- [ ] Implement execution timeline view
- [ ] Add comprehensive event handling tests

## Testing Strategy

### Unit Tests
- Format helper functions
- Command suggestion algorithm
- Event rendering logic

### Integration Tests
- Command execution with rich output
- Progress bar updates during execution
- Error handling with suggestions

### Visual Tests
- Manual testing of UI elements
- Screenshot comparisons
- Terminal compatibility checks

## Risk Mitigation

### Dependency Risk
- Owl library is well-maintained but adds complexity
- Mitigation: Abstract rendering behind interface

### Performance Risk
- Rich UI might slow down output
- Mitigation: Benchmark and optimize hot paths

### Compatibility Risk
- Terminal compatibility varies
- Mitigation: Graceful degradation for basic terminals

## Success Metrics

1. **User Experience**
   - Command execution feels responsive
   - Progress feedback reduces perceived wait time
   - Error messages are helpful with suggestions

2. **Developer Experience**
   - New commands easier to implement
   - Consistent patterns across codebase
   - Clear separation of concerns

3. **Visual Polish**
   - Professional appearance
   - Consistent color scheme
   - Clear information hierarchy

## Implementation Order

1. **Start with Phase 1.2** - Create RendererEnhanced (immediate visual impact)
2. **Then Phase 1.3** - Add FormatHelpers (support functions)
3. **Move to Phase 2.1-2.2** - Base command pattern (developer productivity)
4. **Add Phase 2.3** - Command suggestions (user experience)
5. **Complete with Phase 3** - Agent integration (advanced features)

## Next Steps

1. Review and approve this plan
2. Create feature branch: `feature/cli-enhancements`
3. Begin Phase 1 implementation
4. Iterate based on feedback

## Pattern Library Documentation

Create `docs/patterns/cli-patterns.md` to document:
- Renderer patterns with examples
- Command structure patterns
- Event handling patterns
- Testing patterns for CLI commands

This ensures knowledge transfer and consistency across the team.