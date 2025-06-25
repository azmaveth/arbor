#!/usr/bin/env elixir

defmodule TestFileAnalyzer do
  @moduledoc """
  Analyzes all test files to categorize them for Mox migration planning.
  
  This script identifies:
  1. Integration tests (complex setup, infrastructure dependencies)
  2. Simple mock candidates (hand-written stubs, easy Mox conversion)
  3. Already using Mox (no action needed)
  4. Complex cases requiring dependency injection refactoring
  
  Usage: mix run scripts/analyze_test_files.exs
  """

  @integration_indicators [
    # Infrastructure setup patterns
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
    
    # Complex timing and distributed behavior
    "wait_for_membership_ready",
    "Phoenix.PubSub",
    "GenServer.start_link",
    "Agent.start_link",
    "Task.start_link",
    
    # Real infrastructure components
    "ClusterEvents",
    "ClusterManager",
    "TelemetryHelper"
  ]

  @simple_mock_indicators [
    # Hand-written mock patterns
    "defmodule.*Mock",
    "Application.put_env.*_impl",
    "Application.get_env.*_impl",
    "def .*(_), do:",
    "def .*(_.*), do: {:ok",
    "def .*(_.*), do: :ok",
    
    # Simple stub patterns  
    "@behaviour",
    "use ExUnit.Case, async: true"
  ]

  @already_mox_indicators [
    "import Mox",
    "defmock",
    "expect",
    "stub",
    "verify_on_exit!"
  ]

  @dependency_injection_needs [
    # Hardcoded module calls that need injection
    "HordeRegistry.",
    "HordeSupervisor.", 
    "ClusterRegistry.",
    "ClusterCoordinator.",
    "SessionManager.",
    
    # Direct module dependencies
    "Arbor.Core.",
    "Arbor.Security.",
    "Arbor.Persistence."
  ]

  def run do
    IO.puts("🔍 Analyzing test files for Mox migration planning...\n")
    
    test_files = find_test_files()
    
    IO.puts("Found #{length(test_files)} test files to analyze\n")
    
    analysis = Enum.map(test_files, &analyze_file/1)
    
    generate_report(analysis)
  end

  defp find_test_files do
    Path.wildcard("apps/*/test/**/*_test.exs") ++
    Path.wildcard("test/**/*_test.exs")
  end

  defp analyze_file(file_path) do
    content = File.read!(file_path)
    
    %{
      path: file_path,
      size: byte_size(content),
      lines: length(String.split(content, "\n")),
      category: categorize_file(content),
      indicators: detect_indicators(content),
      complexity_score: calculate_complexity(content),
      migration_effort: estimate_effort(content)
    }
  end

  defp categorize_file(content) do
    cond do
      has_indicators?(content, @already_mox_indicators) ->
        :already_mox
        
      has_indicators?(content, @integration_indicators, 2) ->
        :integration_test
        
      has_indicators?(content, @simple_mock_indicators, 2) and 
      not has_indicators?(content, @integration_indicators, 1) ->
        :simple_mock_candidate
        
      has_indicators?(content, @dependency_injection_needs, 3) ->
        :needs_dependency_injection
        
      true ->
        :other
    end
  end

  defp has_indicators?(content, indicators, min_count \\ 1) do
    matches = Enum.count(indicators, fn indicator ->
      case Regex.compile(indicator) do
        {:ok, regex} -> Regex.match?(regex, content)
        {:error, _} -> String.contains?(content, indicator)
      end
    end)
    
    matches >= min_count
  end

  defp detect_indicators(content) do
    all_indicators = @integration_indicators ++ @simple_mock_indicators ++ 
                    @already_mox_indicators ++ @dependency_injection_needs
    
    Enum.filter(all_indicators, fn indicator ->
      case Regex.compile(indicator) do
        {:ok, regex} -> Regex.match?(regex, content)
        {:error, _} -> String.contains?(content, indicator)
      end
    end)
  end

  defp calculate_complexity(content) do
    # Simple heuristic based on file characteristics
    base_score = 0
    
    base_score
    |> add_if(String.contains?(content, "setup_all"), 2)
    |> add_if(String.contains?(content, "on_exit"), 1)
    |> add_if(String.contains?(content, "async: false"), 2)
    |> add_if(String.contains?(content, "@tag :slow"), 3)
    |> add_if(String.contains?(content, "Process.sleep"), 3)
    |> add_if(String.contains?(content, "wait_until"), 2)
    |> add_if(String.match?(content, ~r/defmodule.*Test.*do/), 1)
    |> add_if(length(String.split(content, "\n")) > 200, 2)
    |> add_if(length(String.split(content, "\n")) > 500, 3)
  end

  defp add_if(score, condition, points) do
    if condition, do: score + points, else: score
  end

  defp estimate_effort(content) do
    complexity = calculate_complexity(content)
    
    cond do
      complexity <= 3 -> :low
      complexity <= 7 -> :medium  
      complexity <= 12 -> :high
      true -> :very_high
    end
  end

  defp generate_report(analysis) do
    # Summary by category
    by_category = Enum.group_by(analysis, & &1.category)
    
    IO.puts("📊 MIGRATION ANALYSIS RESULTS")
    IO.puts("=" |> String.duplicate(50))
    
    Enum.each([:already_mox, :simple_mock_candidate, :needs_dependency_injection, :integration_test, :other], fn category ->
      files = Map.get(by_category, category, [])
      count = length(files)
      
      case category do
        :already_mox ->
          IO.puts("✅ Already using Mox: #{count} files")
          
        :simple_mock_candidate ->
          IO.puts("🎯 Simple Mock Candidates (Quick Wins): #{count} files")
          if count > 0 do
            IO.puts("   Priority candidates:")
            files
            |> Enum.filter(& &1.migration_effort == :low)
            |> Enum.take(5)
            |> Enum.each(fn file ->
              IO.puts("   • #{Path.relative_to_cwd(file.path)} (#{file.lines} lines)")
            end)
          end
          
        :needs_dependency_injection ->
          IO.puts("🔧 Needs Dependency Injection: #{count} files")
          
        :integration_test ->
          IO.puts("🏗️  Integration Tests (Keep + Tag :slow): #{count} files")
          
        :other ->
          IO.puts("❓ Other/Unclear: #{count} files")
      end
      
      IO.puts("")
    end)
    
    # Effort distribution
    by_effort = Enum.group_by(analysis, & &1.migration_effort)
    
    IO.puts("⚡ EFFORT DISTRIBUTION")
    IO.puts("=" |> String.duplicate(30))
    Enum.each([:low, :medium, :high, :very_high], fn effort ->
      count = length(Map.get(by_effort, effort, []))
      IO.puts("#{effort |> to_string() |> String.upcase()}: #{count} files")
    end)
    
    IO.puts("")
    
    # Top quick win candidates
    quick_wins = analysis
    |> Enum.filter(& &1.category == :simple_mock_candidate)
    |> Enum.filter(& &1.migration_effort in [:low, :medium])
    |> Enum.sort_by(& &1.complexity_score)
    |> Enum.take(10)
    
    if length(quick_wins) > 0 do
      IO.puts("🚀 TOP 10 QUICK WIN CANDIDATES")
      IO.puts("=" |> String.duplicate(40))
      Enum.with_index(quick_wins, 1)
      |> Enum.each(fn {file, index} ->
        rel_path = Path.relative_to_cwd(file.path)
        IO.puts("#{index}. #{rel_path}")
        IO.puts("   Lines: #{file.lines}, Effort: #{file.migration_effort}, Score: #{file.complexity_score}")
        if length(file.indicators) > 0 do
          key_indicators = Enum.take(file.indicators, 3)
          IO.puts("   Indicators: #{Enum.join(key_indicators, \", \")}")
        end
        IO.puts("")
      end)
    end
    
    # Summary stats
    total_files = length(analysis)
    already_done = length(Map.get(by_category, :already_mox, []))
    remaining = total_files - already_done
    
    IO.puts("📈 SUMMARY")
    IO.puts("=" |> String.duplicate(20))
    IO.puts("Total test files: #{total_files}")
    IO.puts("Already using Mox: #{already_done}")
    IO.puts("Remaining for migration: #{remaining}")
    
    # Generate detailed CSV for further analysis
    generate_csv_report(analysis)
    
    IO.puts("\n✅ Analysis complete!")
    IO.puts("📄 Detailed results saved to: test_migration_analysis.csv")
    IO.puts("\n🎯 RECOMMENDED NEXT STEPS:")
    IO.puts("1. Start with #{length(Map.get(by_category, :simple_mock_candidate, []))} simple mock candidates")
    IO.puts("2. Focus on #{length(quick_wins)} top quick wins for immediate impact")
    IO.puts("3. Plan dependency injection for #{length(Map.get(by_category, :needs_dependency_injection, []))} complex cases")
  end

  defp generate_csv_report(analysis) do
    csv_content = [
      "path,category,lines,complexity_score,migration_effort,indicators"
      | Enum.map(analysis, fn file ->
        indicators = file.indicators |> Enum.join("; ")
        "#{file.path},#{file.category},#{file.lines},#{file.complexity_score},#{file.migration_effort},\"#{indicators}\""
      end)
    ]
    
    File.write!("test_migration_analysis.csv", Enum.join(csv_content, "\n"))
  end
end

# Run the analysis
TestFileAnalyzer.run()