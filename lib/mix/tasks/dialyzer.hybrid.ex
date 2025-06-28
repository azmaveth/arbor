defmodule Mix.Tasks.Dialyzer.Hybrid do
  @shortdoc "Run Dialyzer with hybrid suppression support"
  
  @moduledoc """
  Runs Dialyzer with support for both ignore file and inline suppressions.
  
  This task provides a hybrid approach where:
  - Dependencies warnings are handled via .dialyzer_ignore.exs
  - Project code (lib/) warnings are handled via inline @dialyzer attributes
  
  ## Usage
  
      mix dialyzer.hybrid
      
  ## Options
  
  All standard dialyzer options are supported.
  """
  
  use Mix.Task
  
  @impl Mix.Task
  def run(args) do
    # Step 1: Run dialyzer without ignore file to get all warnings
    IO.puts("Running Dialyzer analysis...")
    
    # Temporarily backup and modify mix.exs
    backup_and_modify_config()
    
    try do
      # Run dialyzer and capture output
      {output, exit_code} = System.cmd("mix", ["dialyzer", "--format", "short" | args],
        stderr_to_stdout: true,
        env: [{"MIX_ENV", Mix.env() |> to_string()}]
      )
      
      # Parse warnings
      warnings = parse_warnings(output)
      
      # Filter warnings based on hybrid rules
      filtered_warnings = apply_hybrid_filtering(warnings)
      
      # Display results
      display_results(filtered_warnings, exit_code)
      
    after
      # Restore original configuration
      restore_config()
    end
  end
  
  defp backup_and_modify_config do
    # Backup mix.exs
    File.cp!("mix.exs", "mix.exs.hybrid_backup")
    
    # Read current mix.exs
    content = File.read!("mix.exs")
    
    # Comment out ignore_warnings line
    modified = String.replace(content,
      ~r/ignore_warnings:\s*".+?",/,
      "# ignore_warnings: \".dialyzer_ignore.exs\", # Temporarily disabled for hybrid mode"
    )
    
    File.write!("mix.exs", modified)
  end
  
  defp restore_config do
    if File.exists?("mix.exs.hybrid_backup") do
      File.rename!("mix.exs.hybrid_backup", "mix.exs")
    end
  end
  
  defp parse_warnings(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, ":"))
    |> Enum.map(&parse_warning_line/1)
    |> Enum.filter(& &1)
  end
  
  defp parse_warning_line(line) do
    # Parse format: "path/to/file.ex:line:warning_type Description"
    case Regex.run(~r/^(.+?):(\d+):(\w+)\s+(.+)$/, line) do
      [_, file, line, type, description] ->
        %{
          file: file,
          line: String.to_integer(line),
          type: String.to_atom(type),
          description: description,
          raw: line
        }
      _ ->
        nil
    end
  end
  
  defp apply_hybrid_filtering(warnings) do
    # Load ignore patterns from .dialyzer_ignore.exs
    ignore_patterns = load_ignore_patterns()
    
    # Filter warnings
    Enum.filter(warnings, fn warning ->
      cond do
        # Dependencies should be in ignore file
        String.starts_with?(warning.file, "deps/") ->
          not matches_ignore_pattern?(warning, ignore_patterns)
          
        # Project files (lib/) should use inline suppressions
        String.starts_with?(warning.file, "lib/") or
        String.starts_with?(warning.file, "apps/") ->
          # Inline suppressions are already handled by dialyzer
          # So if we see a warning here, it wasn't suppressed inline
          true
          
        # Everything else goes through ignore file
        true ->
          not matches_ignore_pattern?(warning, ignore_patterns)
      end
    end)
  end
  
  defp load_ignore_patterns do
    if File.exists?(".dialyzer_ignore.exs") do
      {patterns, _} = Code.eval_file(".dialyzer_ignore.exs")
      patterns
    else
      []
    end
  end
  
  defp matches_ignore_pattern?(warning, patterns) do
    Enum.any?(patterns, fn
      # Regex pattern
      %Regex{} = regex ->
        Regex.match?(regex, warning.raw)
        
      # Tuple patterns from ignore file
      {file, type, line} when is_binary(file) and is_atom(type) and is_integer(line) ->
        warning.file == file and warning.type == type and warning.line == line
        
      {file, type} when is_binary(file) and is_atom(type) ->
        warning.file == file and warning.type == type
        
      {file, description} when is_binary(file) and is_binary(description) ->
        warning.file == file and String.contains?(warning.description, description)
        
      {file} when is_binary(file) ->
        warning.file == file
        
      _ ->
        false
    end)
  end
  
  defp display_results(warnings, original_exit_code) do
    if Enum.empty?(warnings) do
      IO.puts("\n✅ No warnings found after hybrid filtering!")
      exit({:shutdown, 0})
    else
      IO.puts("\n⚠️  Warnings after hybrid filtering:\n")
      
      Enum.each(warnings, fn warning ->
        IO.puts(warning.raw)
      end)
      
      IO.puts("\nTotal warnings: #{length(warnings)}")
      
      # Exit with original code if there were warnings
      if original_exit_code != 0 do
        exit({:shutdown, original_exit_code})
      end
    end
  end
end