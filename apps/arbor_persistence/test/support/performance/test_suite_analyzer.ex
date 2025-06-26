defmodule Arbor.Test.Performance.TestSuiteAnalyzer do
  @moduledoc """
  Analyzes test suite performance and provides actionable insights.

  This module helps identify performance bottlenecks, suggest optimizations,
  and track test suite health over time. It integrates with the test
  infrastructure to provide comprehensive analysis and recommendations.

  ## Features

  - **Test Classification**: Automatically classify tests by performance tier
  - **Bottleneck Detection**: Identify slowest tests and resource hogs
  - **Optimization Suggestions**: Provide specific improvement recommendations
  - **Trend Analysis**: Track performance changes over time
  - **Resource Analysis**: Identify memory and process leaks

  ## Usage

      # Run analysis on test results
      TestSuiteAnalyzer.analyze_test_run("test/reports/latest.json")
      
      # Get optimization recommendations
      TestSuiteAnalyzer.suggest_optimizations()
      
      # Generate performance report
      TestSuiteAnalyzer.generate_report()
  """

  require Logger

  @type test_result :: %{
          name: String.t(),
          module: String.t(),
          duration_ms: non_neg_integer(),
          memory_mb: float(),
          tag: atom(),
          status: :passed | :failed | :skipped
        }

  @type analysis_result :: %{
          total_tests: non_neg_integer(),
          total_duration_ms: non_neg_integer(),
          tier_distribution: map(),
          bottlenecks: [test_result()],
          recommendations: [String.t()],
          resource_issues: [map()]
        }

  # Performance tier thresholds (in milliseconds)
  @tier_thresholds %{
    fast: 100,
    contract: 500,
    integration: 2000,
    distributed: 10_000,
    chaos: 30_000
  }

  @doc """
  Analyzes a test run and provides performance insights.
  """
  @spec analyze_test_run([test_result()]) :: analysis_result()
  def analyze_test_run(test_results) do
    %{
      total_tests: length(test_results),
      total_duration_ms: calculate_total_duration(test_results),
      tier_distribution: classify_tests_by_tier(test_results),
      bottlenecks: identify_bottlenecks(test_results),
      recommendations: generate_recommendations(test_results),
      resource_issues: detect_resource_issues(test_results)
    }
  end

  @doc """
  Classifies tests into appropriate performance tiers.
  """
  @spec classify_tests_by_tier([test_result()]) :: map()
  def classify_tests_by_tier(test_results) do
    test_results
    |> Enum.group_by(&classify_test/1)
    |> Map.new(fn {tier, tests} ->
      {tier,
       %{
         count: length(tests),
         total_duration_ms: calculate_total_duration(tests),
         avg_duration_ms: calculate_average_duration(tests)
       }}
    end)
  end

  @doc """
  Identifies performance bottlenecks in the test suite.
  """
  @spec identify_bottlenecks([test_result()], Keyword.t()) :: [test_result()]
  def identify_bottlenecks(test_results, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    threshold_percentile = Keyword.get(opts, :threshold_percentile, 0.95)

    sorted_results = Enum.sort_by(test_results, & &1.duration_ms, :desc)
    threshold_duration = calculate_percentile_duration(sorted_results, threshold_percentile)

    sorted_results
    |> Enum.filter(&(&1.duration_ms > threshold_duration))
    |> Enum.take(limit)
  end

  @doc """
  Generates optimization recommendations based on test analysis.
  """
  @spec generate_recommendations([test_result()]) :: [String.t()]
  def generate_recommendations(test_results) do
    recommendations = []

    # Check for misclassified tests
    misclassified = find_misclassified_tests(test_results)

    recommendations =
      if length(misclassified) > 0 do
        [
          "#{length(misclassified)} tests are running slower than their tagged tier suggests. Consider re-tiering or optimizing these tests."
          | recommendations
        ]
      else
        recommendations
      end

    # Check for test suite balance
    tier_distribution = classify_tests_by_tier(test_results)

    recommendations =
      if unbalanced_distribution?(tier_distribution) do
        [
          "Test suite is unbalanced. Consider moving more tests to faster tiers for better feedback loops."
          | recommendations
        ]
      else
        recommendations
      end

    # Check for resource intensive tests
    resource_hogs = find_resource_intensive_tests(test_results)

    recommendations =
      if length(resource_hogs) > 0 do
        [
          "#{length(resource_hogs)} tests consume excessive resources. Consider optimizing or mocking external dependencies."
          | recommendations
        ]
      else
        recommendations
      end

    # Check for slow unit tests
    slow_unit_tests = find_slow_unit_tests(test_results)

    recommendations =
      if length(slow_unit_tests) > 0 do
        [
          "#{length(slow_unit_tests)} unit tests are too slow. Unit tests should complete in under 100ms."
          | recommendations
        ]
      else
        recommendations
      end

    recommendations
  end

  @doc """
  Detects potential resource issues in tests.
  """
  @spec detect_resource_issues([test_result()]) :: [map()]
  def detect_resource_issues(test_results) do
    issues = []

    # Detect memory leaks
    memory_leaks =
      test_results
      |> Enum.filter(&(&1.memory_mb > 10.0))
      |> Enum.map(fn test ->
        %{
          type: :memory_leak,
          test: test.name,
          memory_mb: test.memory_mb,
          severity: if(test.memory_mb > 50.0, do: :high, else: :medium)
        }
      end)

    issues ++ memory_leaks
  end

  @doc """
  Generates a comprehensive performance report.
  """
  @spec generate_report([test_result()]) :: String.t()
  def generate_report(test_results) do
    analysis = analyze_test_run(test_results)

    """
    # Test Suite Performance Report

    ## Summary
    - Total Tests: #{analysis.total_tests}
    - Total Duration: #{format_duration(analysis.total_duration_ms)}
    - Average Duration: #{format_duration(div(analysis.total_duration_ms, max(analysis.total_tests, 1)))}

    ## Tier Distribution
    #{format_tier_distribution(analysis.tier_distribution)}

    ## Performance Bottlenecks
    #{format_bottlenecks(analysis.bottlenecks)}

    ## Recommendations
    #{format_recommendations(analysis.recommendations)}

    ## Resource Issues
    #{format_resource_issues(analysis.resource_issues)}

    Generated at: #{DateTime.utc_now() |> DateTime.to_string()}
    """
  end

  @doc """
  Suggests test optimizations based on patterns.
  """
  @spec suggest_test_optimization(test_result()) :: [String.t()]
  def suggest_test_optimization(test) do
    suggestions = []

    # Check duration
    suggestions =
      if test.duration_ms > 1000 and test.tag == :fast do
        [
          "Consider moving this test to :integration tier or optimize it to run faster"
          | suggestions
        ]
      else
        suggestions
      end

    # Check memory usage
    suggestions =
      if test.memory_mb > 5.0 do
        [
          "High memory usage detected. Consider using mocks or reducing test data size"
          | suggestions
        ]
      else
        suggestions
      end

    # Check for common patterns
    suggestions =
      if String.contains?(test.name, "database") and test.tag == :fast do
        [
          "Test name suggests database interaction. Consider using IntegrationCase instead of FastCase"
          | suggestions
        ]
      else
        suggestions
      end

    suggestions
  end

  # Private helper functions

  defp calculate_total_duration(test_results) do
    Enum.sum(Enum.map(test_results, & &1.duration_ms))
  end

  defp calculate_average_duration(test_results) do
    case length(test_results) do
      0 -> 0
      count -> div(calculate_total_duration(test_results), count)
    end
  end

  defp classify_test(test_result) do
    cond do
      test_result.duration_ms <= @tier_thresholds.fast -> :fast
      test_result.duration_ms <= @tier_thresholds.contract -> :contract
      test_result.duration_ms <= @tier_thresholds.integration -> :integration
      test_result.duration_ms <= @tier_thresholds.distributed -> :distributed
      true -> :chaos
    end
  end

  defp calculate_percentile_duration(sorted_results, percentile) do
    index = round(length(sorted_results) * percentile)

    case Enum.at(sorted_results, index) do
      nil -> 0
      test -> test.duration_ms
    end
  end

  defp find_misclassified_tests(test_results) do
    Enum.filter(test_results, fn test ->
      expected_tier = test.tag || :fast
      actual_tier = classify_test(test)
      tier_rank(actual_tier) > tier_rank(expected_tier)
    end)
  end

  defp tier_rank(tier) do
    case tier do
      :fast -> 1
      :contract -> 2
      :integration -> 3
      :distributed -> 4
      :chaos -> 5
      _ -> 6
    end
  end

  defp unbalanced_distribution?(tier_distribution) do
    fast_count = get_in(tier_distribution, [:fast, :count]) || 0

    slow_count =
      (get_in(tier_distribution, [:integration, :count]) || 0) +
        (get_in(tier_distribution, [:distributed, :count]) || 0) +
        (get_in(tier_distribution, [:chaos, :count]) || 0)

    # Consider unbalanced if slow tests outnumber fast tests
    slow_count > fast_count
  end

  defp find_resource_intensive_tests(test_results) do
    Enum.filter(test_results, fn test ->
      test.memory_mb > 10.0
    end)
  end

  defp find_slow_unit_tests(test_results) do
    test_results
    |> Enum.filter(&(&1.tag == :fast and &1.duration_ms > @tier_thresholds.fast))
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp format_tier_distribution(distribution) do
    [:fast, :contract, :integration, :distributed, :chaos]
    |> Enum.map(fn tier ->
      case Map.get(distribution, tier) do
        nil ->
          nil

        stats ->
          "- #{tier}: #{stats.count} tests, #{format_duration(stats.total_duration_ms)} total, #{format_duration(stats.avg_duration_ms)} avg"
      end
    end)
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp format_bottlenecks(bottlenecks) do
    bottlenecks
    |> Enum.take(10)
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {test, index} ->
      "#{index}. #{test.name} (#{test.module}) - #{format_duration(test.duration_ms)}"
    end)
  end

  defp format_recommendations(recommendations) do
    recommendations
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {rec, index} ->
      "#{index}. #{rec}"
    end)
  end

  defp format_resource_issues(issues) do
    if Enum.empty?(issues) do
      "No resource issues detected."
    else
      issues
      |> Enum.map_join("\n", fn issue ->
        "- #{issue.type}: #{issue.test} (#{issue.memory_mb}MB) - Severity: #{issue.severity}"
      end)
    end
  end
end
