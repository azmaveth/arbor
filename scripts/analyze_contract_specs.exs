#!/usr/bin/env elixir

# Script to analyze contract specification warnings and suggest fixes

defmodule ContractSpecAnalyzer do
  def run do
    IO.puts("Analyzing Contract Specification Warnings")
    IO.puts("=" <> String.duplicate("=", 50))
    
    # Get dialyzer output
    {output, _} = System.cmd("mix", ["dialyzer", "--format", "short"], 
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "dev"}]
    )
    
    # Parse warnings
    warnings = parse_warnings(output)
    
    # Group by type
    grouped = group_warnings(warnings)
    
    # Analyze each type
    analyze_contract_supertypes(grouped[:contract_supertype] || [])
    analyze_extra_ranges(grouped[:extra_range] || [])
    analyze_callback_mismatches(grouped[:callback_spec_arg_type_mismatch] || [])
    analyze_unknown_types(grouped[:unknown_type] || [])
    
    # Summary
    print_summary(grouped)
  end
  
  defp parse_warnings(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/^(lib|apps)/))
    |> Enum.map(&parse_warning_line/1)
    |> Enum.filter(& &1)
  end
  
  defp parse_warning_line(line) do
    case Regex.run(~r/^(.+?):(\d+):(\w+)\s+(.+)$/, line) do
      [_, file, line_num, type, desc] ->
        %{
          file: file,
          line: String.to_integer(line_num),
          type: String.to_atom(type),
          description: desc,
          raw: line
        }
      _ ->
        # Try alternative format
        case Regex.run(~r/^(.+?):(\d+):(\d+):(\w+)\s+(.+)$/, line) do
          [_, file, line_num, _col, type, desc] ->
            %{
              file: file,
              line: String.to_integer(line_num),
              type: String.to_atom(type),
              description: desc,
              raw: line
            }
          _ ->
            nil
        end
    end
  end
  
  defp group_warnings(warnings) do
    Enum.group_by(warnings, & &1.type)
  end
  
  defp analyze_contract_supertypes(warnings) do
    IO.puts("\n## Contract Supertype Warnings (#{length(warnings)})")
    IO.puts("These specs are too general compared to what the function actually returns.\n")
    
    warnings
    |> Enum.take(5)
    |> Enum.each(fn w ->
      IO.puts("File: #{w.file}:#{w.line}")
      IO.puts("Issue: #{w.description}")
      
      # Extract function name if possible
      case Regex.run(~r/Type specification for (\w+)/, w.description) do
        [_, func] ->
          IO.puts("Fix: Make the @spec for #{func}/n more specific")
        _ ->
          IO.puts("Fix: Narrow the type specification to match actual return values")
      end
      
      IO.puts("")
    end)
    
    if length(warnings) > 5 do
      IO.puts("... and #{length(warnings) - 5} more")
    end
  end
  
  defp analyze_extra_ranges(warnings) do
    IO.puts("\n## Extra Range Warnings (#{length(warnings)})")
    IO.puts("These specs include error cases that never actually occur.\n")
    
    warnings
    |> Enum.take(5)
    |> Enum.each(fn w ->
      IO.puts("File: #{w.file}:#{w.line}")
      IO.puts("Issue: #{w.description}")
      
      # Check if it's about {:error, _}
      if String.contains?(w.description, "{:error, _}") do
        IO.puts("Fix: Remove {:error, _} from the @spec - this function never fails")
      else
        IO.puts("Fix: Remove the extra type from the specification")
      end
      
      IO.puts("")
    end)
    
    if length(warnings) > 5 do
      IO.puts("... and #{length(warnings) - 5} more")
    end
  end
  
  defp analyze_callback_mismatches(warnings) do
    IO.puts("\n## Callback Specification Mismatches (#{length(warnings)})")
    IO.puts("These implementations don't match their behaviour callbacks.\n")
    
    Enum.each(warnings, fn w ->
      IO.puts("File: #{w.file}:#{w.line}")
      IO.puts("Issue: #{w.description}")
      IO.puts("Fix: Update the implementation to match the behaviour's expected types")
      IO.puts("")
    end)
  end
  
  defp analyze_unknown_types(warnings) do
    IO.puts("\n## Unknown Type Warnings (#{length(warnings)})")
    IO.puts("These specs reference types that aren't defined.\n")
    
    Enum.each(warnings, fn w ->
      IO.puts("File: #{w.file}:#{w.line}")
      IO.puts("Issue: #{w.description}")
      
      case Regex.run(~r/Unknown type: (.+)\./, w.description) do
        [_, type] ->
          IO.puts("Fix: Define the type #{type} or use a built-in type")
        _ ->
          IO.puts("Fix: Define the missing type or import it")
      end
      
      IO.puts("")
    end)
  end
  
  defp print_summary(grouped) do
    IO.puts("\n## Summary")
    IO.puts("=" <> String.duplicate("=", 50))
    
    grouped
    |> Enum.sort_by(fn {_, warnings} -> -length(warnings) end)
    |> Enum.each(fn {type, warnings} ->
      IO.puts("#{type}: #{length(warnings)} warnings")
    end)
    
    total = grouped |> Map.values() |> List.flatten() |> length()
    IO.puts("\nTotal contract/type warnings: #{total}")
    
    IO.puts("\n## Recommended Fix Order:")
    IO.puts("1. Unknown types - Define missing types")
    IO.puts("2. Extra ranges - Remove {:error, _} from specs that never fail")
    IO.puts("3. Contract supertypes - Make specs more specific")
    IO.puts("4. Callback mismatches - Align with behaviour definitions")
  end
end

ContractSpecAnalyzer.run()