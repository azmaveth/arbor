defmodule Mix.Tasks.Test.Analyze do
  use Mix.Task

  @shortdoc "Analyzes test suite performance"

  @moduledoc """
  Analyzes test suite performance and provides optimization recommendations.

  This task runs the test suite with performance monitoring enabled,
  collects metrics, and generates a comprehensive analysis report with
  actionable recommendations for improving test performance.

  ## Usage

      mix test.analyze                    # Analyze all tests
      mix test.analyze --only fast       # Analyze only fast tests
      mix test.analyze --tag integration # Analyze integration tests
      mix test.analyze --save            # Save analysis to file

  ## Options

    * `--only` - Run analysis on specific test tier
    * `--tag` - Run analysis on tests with specific tag
    * `--save` - Save analysis report to file
    * `--json` - Output analysis as JSON
    * `--threshold` - Set custom performance thresholds

  ## Examples

      # Analyze all tests and save report
      mix test.analyze --save
      
      # Analyze slow tests
      mix test.analyze --tag integration --tag distributed
      
      # Get JSON output for CI integration
      mix test.analyze --json
  """

  use Mix.Task

  # Mix tasks use Mix environment functions not available during static analysis
  @dialyzer {:nowarn_function, run: 1}

  # TestSuiteAnalyzer is only available in test environment
  @dialyzer [
    {:nowarn_function, analyze_with_suite_analyzer: 1},
    {:nowarn_function, generate_analysis_report: 1}
  ]

  # Note: TestSuiteAnalyzer is in test/support and only available in test environment

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        switches: [
          only: :string,
          tag: :keep,
          save: :boolean,
          json: :boolean,
          threshold: :integer
        ]
      )

    # Start application for test analysis
    if function_exported?(Mix.Task, :run, 1) do
      Mix.Task.run("app.start")
    end

    IO.puts("\n🔍 Analyzing test suite performance...\n")

    # Collect test results
    test_results = collect_test_results(opts)

    # Run analysis
    analysis = analyze_with_suite_analyzer(test_results)

    # Output results
    if opts[:json] do
      output_json(analysis)
    else
      output_report(analysis, opts)
    end

    # Check for critical issues
    check_critical_issues(analysis)
  end

  defp collect_test_results(opts) do
    # Run tests with performance monitoring
    test_args = build_test_args(opts)

    # Capture test output and parse results
    {output, _exit_code} =
      System.cmd("mix", ["test" | test_args],
        env: [{"TEST_PERFORMANCE_MONITOR", "true"}],
        stderr_to_stdout: true
      )

    # Parse test results from output
    parse_test_results(output)
  end

  defp build_test_args(opts) do
    args = []

    args =
      if opts[:only] do
        ["--only", opts[:only] | args]
      else
        args
      end

    args =
      Enum.reduce(Keyword.get_values(opts, :tag), args, fn tag, acc ->
        ["--tag", tag | acc]
      end)

    args ++ ["--formatter", "Arbor.Test.PerformanceFormatter"]
  end

  defp parse_test_results(output) do
    # Parse performance data from test output
    # This is a simplified parser - in production, use a proper formatter
    output
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, "PERF:"))
    |> Enum.map(&parse_performance_line/1)
    |> Enum.filter(& &1)
  end

  defp parse_performance_line(line) do
    case Regex.run(~r/PERF: (.+?) \((.+?)\) - (\d+)ms, ([\d.]+)MB/, line) do
      [_, test_name, module, duration_str, memory_str] ->
        %{
          name: test_name,
          module: module,
          duration_ms: String.to_integer(duration_str),
          memory_mb: String.to_float(memory_str),
          tag: :unknown,
          status: :passed
        }

      _ ->
        nil
    end
  end

  defp output_report(analysis, opts) do
    report = generate_analysis_report(analysis)

    IO.puts(report)

    if opts[:save] do
      filename = "test_analysis_#{timestamp()}.md"
      File.write!(filename, report)
      IO.puts("\n📄 Report saved to: #{filename}")
    end
  end

  defp output_json(analysis) do
    json = Jason.encode!(analysis, pretty: true)
    IO.puts(json)
  end

  defp check_critical_issues(analysis) do
    critical_issues = []

    # Check for severe bottlenecks
    critical_issues =
      if length(analysis.bottlenecks) > 20 do
        ["More than 20 performance bottlenecks detected" | critical_issues]
      else
        critical_issues
      end

    # Check for resource issues
    critical_issues =
      if length(analysis.resource_issues) > 0 do
        high_severity = Enum.filter(analysis.resource_issues, &(&1.severity == :high))

        if length(high_severity) > 0 do
          ["#{length(high_severity)} high-severity resource issues detected" | critical_issues]
        else
          critical_issues
        end
      else
        critical_issues
      end

    if length(critical_issues) > 0 do
      IO.puts("\n⚠️  Critical Issues Detected:")

      Enum.each(critical_issues, fn issue ->
        IO.puts("   - #{issue}")
      end)

      # Exit with error code for CI
      exit({:shutdown, 1})
    else
      IO.puts("\n✅ No critical performance issues detected")
    end
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9]/, "")
    |> String.slice(0..13)
  end

  # TestSuiteAnalyzer is only available in test environment
  # Dialyzer warnings about undefined module are suppressed in .dialyzer_ignore.exs

  defp analyze_with_suite_analyzer(test_results) do
    module = Arbor.Test.Performance.TestSuiteAnalyzer

    if Code.ensure_loaded?(module) and function_exported?(module, :analyze_test_run, 1) do
      module.analyze_test_run(test_results)
    else
      IO.puts("""
      ⚠️  TestSuiteAnalyzer not available.

      This task requires test support modules. Please run:
        MIX_ENV=test mix test.analyze
      """)

      System.halt(1)
    end
  end

  defp generate_analysis_report(analysis) do
    module = Arbor.Test.Performance.TestSuiteAnalyzer

    if Code.ensure_loaded?(module) and function_exported?(module, :generate_report, 1) do
      module.generate_report(analysis)
    else
      ""
    end
  end
end
