#!/usr/bin/env elixir

# Script to migrate suppressions from .dialyzer_ignore.exs to inline @dialyzer attributes

defmodule SuppresionMigrator do
  def run do
    IO.puts("Migrating Dialyzer suppressions to inline attributes")
    IO.puts("=" <> String.duplicate("=", 50))
    
    # Load current ignore patterns
    {patterns, _} = Code.eval_file(".dialyzer_ignore.exs")
    
    # Group patterns by file
    patterns_by_file = group_patterns_by_file(patterns)
    
    # Process each file
    results = Enum.map(patterns_by_file, fn {file, file_patterns} ->
      if should_use_inline?(file) do
        migrate_file(file, file_patterns)
      else
        {:keep_in_ignore, file}
      end
    end)
    
    # Generate new ignore file with only deps/ patterns
    generate_new_ignore_file(patterns)
    
    # Report results
    report_results(results)
  end
  
  defp group_patterns_by_file(patterns) do
    Enum.reduce(patterns, %{}, fn pattern, acc ->
      file = extract_file_from_pattern(pattern)
      if file do
        Map.update(acc, file, [pattern], &[pattern | &1])
      else
        acc
      end
    end)
  end
  
  defp extract_file_from_pattern(pattern) do
    case pattern do
      {file, _, _} when is_binary(file) -> file
      {file, _} when is_binary(file) -> file
      {file} when is_binary(file) -> file
      _ -> nil
    end
  end
  
  defp should_use_inline?(file) do
    String.starts_with?(file, "lib/") or String.starts_with?(file, "apps/")
  end
  
  defp migrate_file(file, patterns) do
    IO.puts("\nMigrating #{file}...")
    
    if File.exists?(file) do
      content = File.read!(file)
      
      # Extract suppression info
      suppressions = Enum.map(patterns, &pattern_to_suppression/1)
      |> Enum.filter(& &1)
      |> Enum.uniq()
      
      # Add suppressions to file
      new_content = add_inline_suppressions(content, suppressions)
      
      if new_content != content do
        File.write!(file, new_content)
        {:migrated, file, length(suppressions)}
      else
        {:already_suppressed, file}
      end
    else
      {:file_not_found, file}
    end
  end
  
  defp pattern_to_suppression(pattern) do
    case pattern do
      {_, :pattern_match_cov} ->
        # This is from AgentBehavior macro - add module-level suppression
        {:module, :pattern_match_cov}
        
      {_, :pattern_match, line} ->
        # Function-specific pattern match
        {:function, :pattern_match, line}
        
      {_, :callback_spec_arg_type_mismatch} ->
        {:module, :callback_spec_arg_type_mismatch}
        
      {_, :call} ->
        {:module, :call}
        
      _ ->
        nil
    end
  end
  
  defp add_inline_suppressions(content, suppressions) do
    lines = String.split(content, "\n")
    
    # Check if suppressions already exist
    has_dialyzer_attr = Enum.any?(lines, &String.contains?(&1, "@dialyzer"))
    
    if has_dialyzer_attr do
      content  # Already has suppressions
    else
      # Add suppressions after moduledoc
      add_after_moduledoc(lines, suppressions)
    end
  end
  
  defp add_after_moduledoc(lines, suppressions) do
    # Find where to insert suppressions
    moduledoc_end = find_moduledoc_end(lines)
    
    # Generate suppression attributes
    suppression_lines = generate_suppression_lines(suppressions)
    
    # Insert suppressions
    {before, after_} = Enum.split(lines, moduledoc_end + 1)
    
    (before ++ [""] ++ suppression_lines ++ [""] ++ after_)
    |> Enum.join("\n")
  end
  
  defp find_moduledoc_end(lines) do
    in_moduledoc = false
    
    Enum.find_index(lines, fn line ->
      cond do
        String.contains?(line, "@moduledoc \"\"\"") -> 
          in_moduledoc = true
          false
        in_moduledoc and String.trim(line) == "\"\"\"" ->
          true
        String.contains?(line, "@moduledoc") ->
          true
        true ->
          false
      end
    end) || 2  # Default to after module definition
  end
  
  defp generate_suppression_lines(suppressions) do
    suppressions
    |> Enum.map(fn
      {:module, warning_type} ->
        "  # Dialyzer suppression for #{warning_type} warnings"
        "  @dialyzer {:no_#{warning_type}, []}"
        
      {:function, warning_type, _line} ->
        "  # TODO: Add function-specific suppression for #{warning_type}"
        "  # @dialyzer {:nowarn_function, function_name: arity}"
    end)
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
  end
  
  defp generate_new_ignore_file(patterns) do
    # Keep only deps/ and non-file patterns
    kept_patterns = Enum.filter(patterns, fn pattern ->
      file = extract_file_from_pattern(pattern)
      
      cond do
        is_nil(file) -> true  # Keep regex patterns
        String.starts_with?(file, "deps/") -> true
        not should_use_inline?(file) -> true
        true -> false
      end
    end)
    
    # Write new ignore file
    content = """
    # Dialyzer ignore file - for dependencies only
    # Project code should use inline @dialyzer attributes
    
    [
    #{format_patterns(kept_patterns)}
    ]
    """
    
    File.write!(".dialyzer_ignore.exs.new", content)
    IO.puts("\n📝 New ignore file written to .dialyzer_ignore.exs.new")
  end
  
  defp format_patterns(patterns) do
    patterns
    |> Enum.map(&"  #{inspect(&1)}")
    |> Enum.join(",\n")
  end
  
  defp report_results(results) do
    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("Migration Summary:")
    
    results
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.each(fn {status, items} ->
      case status do
        :migrated ->
          IO.puts("\n✅ Migrated #{length(items)} files:")
          Enum.each(items, fn {_, file, count} ->
            IO.puts("   - #{file} (#{count} suppressions)")
          end)
          
        :keep_in_ignore ->
          IO.puts("\n📋 Keeping #{length(items)} files in ignore file:")
          Enum.each(items, fn {_, file} ->
            IO.puts("   - #{file}")
          end)
          
        :already_suppressed ->
          IO.puts("\n✓ Already suppressed: #{length(items)} files")
          
        :file_not_found ->
          IO.puts("\n❌ Files not found: #{length(items)}")
          Enum.each(items, fn {_, file} ->
            IO.puts("   - #{file}")
          end)
      end
    end)
    
    IO.puts("\n📌 Next steps:")
    IO.puts("1. Review the generated suppressions in modified files")
    IO.puts("2. Update function-specific suppressions with correct function names")
    IO.puts("3. Replace .dialyzer_ignore.exs with .dialyzer_ignore.exs.new")
    IO.puts("4. Test with: mix dialyzer")
  end
end

# Run the migration
SuppresionMigrator.run()