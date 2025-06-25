#!/usr/bin/env elixir

defmodule SimpleTestAnalyzer do
  @moduledoc """
  Simple test file analyzer that doesn't require application startup.
  
  Categorizes test files for Mox migration by analyzing file content.
  """

  @integration_indicators [
    "start_supervised",
    "ensure_horde_infrastructure", 
    "Horde.Registry",
    "Horde.DynamicSupervisor",
    "Horde.Cluster",
    "@moduletag :integration",
    "@tag :integration",
    "AsyncHelpers.wait_until",
    "Process.sleep",
    "receive",
    "wait_for_membership_ready",
    "Phoenix.PubSub",
    "GenServer.start_link",
    "Agent.start_link"
  ]

  @simple_mock_indicators [
    "defmodule.*Mock",
    "Application.put_env.*_impl",
    "def.*(_), do:",
    "def.*(_.*), do: {:ok",
    "def.*(_.*), do: :ok",
    "@behaviour",
    "use ExUnit.Case, async: true"
  ]

  @mox_indicators [
    "import Mox",
    "defmock",
    "expect",
    "stub",
    "verify_on_exit!"
  ]

  def run do
    IO.puts("🔍 Analyzing test files for Mox migration...\n")
    
    test_files = find_test_files()
    IO.puts("Found #{length(test_files)} test files\n")
    
    analysis = Enum.map(test_files, &analyze_file/1)
    
    generate_report(analysis)
  end

  defp find_test_files do
    (Path.wildcard("apps/*/test/**/*_test.exs") ++
     Path.wildcard("test/**/*_test.exs"))
    |> Enum.filter(&File.exists?/1)
  end

  defp analyze_file(file_path) do
    try do
      content = File.read!(file_path)
      
      %{
        path: file_path,
        lines: content |> String.split("\n") |> length(),
        category: categorize_file(content),
        indicators: detect_indicators(content),
        complexity: calculate_complexity(content)
      }
    rescue
      _ -> 
        %{path: file_path, lines: 0, category: :error, indicators: [], complexity: 0}
    end
  end

  defp categorize_file(content) do
    cond do
      has_indicators?(content, @mox_indicators) ->
        :already_mox
        
      has_indicators?(content, @integration_indicators, 2) ->
        :integration_test
        
      has_indicators?(content, @simple_mock_indicators, 2) and 
      not has_indicators?(content, @integration_indicators) ->
        :simple_mock_candidate
        
      String.contains?(content, "Arbor.Core.") or 
      String.contains?(content, "HordeRegistry.") ->
        :needs_dependency_injection
        
      true ->
        :other
    end
  end

  defp has_indicators?(content, indicators, min_count \\ 1) do
    matches = Enum.count(indicators, fn indicator ->
      String.contains?(content, indicator)
    end)
    
    matches >= min_count
  end

  defp detect_indicators(content) do
    all_indicators = @integration_indicators ++ @simple_mock_indicators ++ @mox_indicators
    
    Enum.filter(all_indicators, fn indicator ->
      String.contains?(content, indicator)
    end)
  end

  defp calculate_complexity(content) do
    lines = content |> String.split("\n") |> length()
    
    base = cond do
      lines > 500 -> 5
      lines > 200 -> 3  
      lines > 100 -> 2
      true -> 1
    end
    
    modifiers = [
      {"setup_all", 2},
      {"async: false", 2},
      {"@tag :slow", 3},
      {"Process.sleep", 3},
      {"wait_until", 2},
      {"start_supervised", 2}
    ]
    
    Enum.reduce(modifiers, base, fn {pattern, points}, acc ->
      if String.contains?(content, pattern), do: acc + points, else: acc
    end)
  end

  defp generate_report(analysis) do
    by_category = Enum.group_by(analysis, & &1.category)
    
    IO.puts("📊 MIGRATION ANALYSIS RESULTS")
    IO.puts(String.duplicate("=", 50))
    
    print_category(:already_mox, "✅ Already using Mox", by_category)
    print_category(:simple_mock_candidate, "🎯 Simple Mock Candidates (Quick Wins)", by_category)  
    print_category(:needs_dependency_injection, "🔧 Needs Dependency Injection", by_category)
    print_category(:integration_test, "🏗️  Integration Tests (Keep + Tag :slow)", by_category)
    print_category(:other, "❓ Other/Unclear", by_category)
    
    # Detailed file lists for key categories
    IO.puts("\n📄 DETAILED FILE LISTS")
    IO.puts(String.duplicate("=", 30))
    
    print_detailed_files(:needs_dependency_injection, "🔧 Needs Dependency Injection Files", by_category)
    print_detailed_files(:other, "❓ Other/Unclear Files", by_category)
    print_detailed_files(:integration_test, "🏗️ Integration Test Files", by_category)
    
    # Show quick wins
    quick_wins = by_category
    |> Map.get(:simple_mock_candidate, [])
    |> Enum.sort_by(& &1.complexity)
    |> Enum.take(10)
    
    if length(quick_wins) > 0 do
      IO.puts("\n🚀 TOP 10 QUICK WIN CANDIDATES")
      IO.puts(String.duplicate("=", 40))
      
      quick_wins
      |> Enum.with_index(1)
      |> Enum.each(fn {file, index} ->
        rel_path = Path.relative_to_cwd(file.path)
        IO.puts("#{index}. #{rel_path}")
        IO.puts("   Lines: #{file.lines}, Complexity: #{file.complexity}")
        
        key_indicators = Enum.take(file.indicators, 3)
        if length(key_indicators) > 0 do
          IO.puts("   Indicators: #{Enum.join(key_indicators, ", ")}")
        end
        IO.puts("")
      end)
    end
    
    # Summary
    total = length(analysis)
    already_done = length(Map.get(by_category, :already_mox, []))
    
    IO.puts("📈 SUMMARY")
    IO.puts(String.duplicate("=", 20))
    IO.puts("Total test files: #{total}")
    IO.puts("Already using Mox: #{already_done}")
    IO.puts("Remaining for migration: #{total - already_done}")
    
    IO.puts("\n🎯 RECOMMENDED NEXT STEPS:")
    IO.puts("1. Start with #{length(Map.get(by_category, :simple_mock_candidate, []))} simple mock candidates")
    IO.puts("2. Focus on #{length(quick_wins)} top quick wins")
    IO.puts("3. Plan dependency injection for #{length(Map.get(by_category, :needs_dependency_injection, []))} complex cases")
  end

  defp print_category(category, label, by_category) do
    files = Map.get(by_category, category, [])
    count = length(files)
    IO.puts("#{label}: #{count} files")
    
    if count > 0 and category == :simple_mock_candidate do
      IO.puts("   Priority files:")
      files
      |> Enum.sort_by(& &1.complexity)
      |> Enum.take(5)
      |> Enum.each(fn file ->
        rel_path = Path.relative_to_cwd(file.path)
        IO.puts("   • #{rel_path} (#{file.lines} lines)")
      end)
    end
    
    IO.puts("")
  end

  defp print_detailed_files(category, label, by_category) do
    files = Map.get(by_category, category, [])
    
    if length(files) > 0 do
      IO.puts("#{label}:")
      files
      |> Enum.sort_by(& &1.complexity)
      |> Enum.each(fn file ->
        rel_path = Path.relative_to_cwd(file.path)
        IO.puts("  • #{rel_path} (#{file.lines} lines, complexity: #{file.complexity})")
        
        if length(file.indicators) > 0 do
          key_indicators = Enum.take(file.indicators, 3)
          IO.puts("    Indicators: #{Enum.join(key_indicators, ", ")}")
        end
      end)
      IO.puts("")
    end
  end
end

SimpleTestAnalyzer.run()