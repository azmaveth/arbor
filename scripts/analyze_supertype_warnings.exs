#!/usr/bin/env elixir

# Script to analyze contract_supertype warnings and suggest fixes

defmodule SupertypeAnalyzer do
  def run do
    IO.puts("Analyzing contract_supertype warnings...\n")
    
    warnings = get_dialyzer_warnings()
    |> parse_supertype_warnings()
    |> Enum.sort_by(& &1.file)
    
    IO.puts("Found #{length(warnings)} contract_supertype warnings\n")
    
    Enum.each(warnings, fn warning ->
      IO.puts("File: #{warning.file}:#{warning.line}")
      IO.puts("Function: #{warning.function}")
      IO.puts("Current spec: #{warning.spec}")
      IO.puts("Success typing: #{warning.success_typing}")
      IO.puts("Suggestion: #{suggest_fix(warning)}")
      IO.puts(String.duplicate("-", 80))
    end)
    
    # Group by common patterns
    IO.puts("\n\nCommon Patterns:")
    warnings
    |> Enum.group_by(&categorize_warning/1)
    |> Enum.each(fn {category, warns} ->
      IO.puts("\n#{category}: #{length(warns)} warnings")
      warns |> Enum.take(3) |> Enum.each(fn w ->
        IO.puts("  - #{w.file}:#{w.line} #{w.function}")
      end)
    end)
  end
  
  defp get_dialyzer_warnings do
    {output, _} = System.cmd("mix", ["dialyzer"], stderr_to_stdout: true)
    output
  end
  
  defp parse_supertype_warnings(output) do
    output
    |> String.split("\n")
    |> parse_lines([])
    |> Enum.filter(& &1.type == :contract_supertype)
  end
  
  defp parse_lines([], acc), do: Enum.reverse(acc)
  defp parse_lines([line | rest], acc) do
    cond do
      String.contains?(line, ":contract_supertype") ->
        [file_info | _] = String.split(line, ":")
        [file, line_no] = String.split(file_info, ":")
        
        # Get next lines for details
        {details, remaining} = extract_warning_details(rest)
        
        warning = %{
          type: :contract_supertype,
          file: file,
          line: line_no,
          function: extract_function(details),
          spec: extract_spec(details),
          success_typing: extract_success_typing(details)
        }
        
        parse_lines(remaining, [warning | acc])
        
      true ->
        parse_lines(rest, acc)
    end
  end
  
  defp extract_warning_details(lines) do
    # Take lines until we hit the next warning or end
    {details, rest} = Enum.split_while(lines, fn line ->
      not String.contains?(line, "________________") or
      String.trim(line) == ""
    end)
    
    {details, rest}
  end
  
  defp extract_function(details) do
    case Enum.find(details, &String.contains?(&1, "Function:")) do
      nil -> "unknown"
      line -> 
        line
        |> String.split("Function:")
        |> List.last()
        |> String.trim()
    end
  end
  
  defp extract_spec(details) do
    in_spec = false
    
    details
    |> Enum.reduce({false, []}, fn line, {capturing, acc} ->
      cond do
        String.contains?(line, "Type specification:") ->
          {true, acc}
        String.contains?(line, "Success typing:") ->
          {false, acc}
        capturing and String.trim(line) != "" ->
          {true, [line | acc]}
        true ->
          {capturing, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join(" ")
    |> String.trim()
  end
  
  defp extract_success_typing(details) do
    in_success = false
    
    details
    |> Enum.reduce({false, []}, fn line, {capturing, acc} ->
      cond do
        String.contains?(line, "Success typing:") ->
          {true, acc}
        capturing and String.starts_with?(line, "___") ->
          {false, acc}
        capturing and String.trim(line) != "" ->
          {true, [line | acc]}
        true ->
          {capturing, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join(" ")
    |> String.trim()
  end
  
  defp categorize_warning(warning) do
    cond do
      String.contains?(warning.spec, "any()") -> "Specs using any()"
      String.contains?(warning.spec, "term()") -> "Specs using term()"
      String.contains?(warning.spec, "atom()") -> "Specs using atom() instead of specific atoms"
      String.contains?(warning.spec, "binary()") -> "Specs using binary() instead of String.t()"
      String.contains?(warning.spec, "map()") and String.contains?(warning.success_typing, "%{") -> 
        "Specs using map() instead of specific map structure"
      String.contains?(warning.function, "process/1") -> "Process function specs too general"
      true -> "Other"
    end
  end
  
  defp suggest_fix(warning) do
    success = warning.success_typing
    
    cond do
      # If spec uses any() but success typing is specific
      String.contains?(warning.spec, "any()") ->
        "Replace any() with the actual type from success typing"
        
      # If spec uses term() but success typing is more specific
      String.contains?(warning.spec, "term()") ->
        "Replace term() with more specific type"
        
      # If spec uses atom() but success typing shows specific atoms
      String.contains?(warning.spec, "atom()") and String.contains?(success, ":") ->
        atoms = extract_atoms_from_success(success)
        "Replace atom() with specific atoms: #{inspect(atoms)}"
        
      # If spec uses map() but success typing shows specific structure
      String.contains?(warning.spec, "map()") and String.contains?(success, "%{") ->
        "Replace map() with specific map structure from success typing"
        
      true ->
        "Tighten the spec to match success typing"
    end
  end
  
  defp extract_atoms_from_success(success_typing) do
    success_typing
    |> String.split(~r/[\s,\|\(\)]+/)
    |> Enum.filter(&String.starts_with?(&1, ":"))
    |> Enum.uniq()
    |> Enum.sort()
  end
end

SupertypeAnalyzer.run()