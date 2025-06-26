defmodule Arbor.Test.Reporting.HtmlPerformanceReporter do
  @moduledoc """
  Generates interactive HTML reports for test suite performance analysis.

  This module creates visual reports with charts, graphs, and interactive
  elements to help developers understand test suite performance characteristics
  and identify optimization opportunities.

  ## Features

  - **Performance Timeline**: Visual timeline of test execution
  - **Resource Usage Graphs**: Memory and process count over time
  - **Tier Distribution Charts**: Test distribution across performance tiers
  - **Bottleneck Analysis**: Interactive list of slowest tests
  - **Trend Analysis**: Historical performance comparison

  ## Usage

      # Generate HTML report from test results
      HtmlPerformanceReporter.generate_report(test_results, "report.html")
      
      # Generate with historical data
      HtmlPerformanceReporter.generate_trend_report(test_runs, "trend_report.html")
  """

  @type test_result :: map()
  @type report_options :: keyword()

  @doc """
  Generates an HTML performance report from test results.
  """
  @spec generate_report([test_result()], String.t(), report_options()) :: :ok | {:error, term()}
  def generate_report(test_results, output_path, opts \\ []) do
    analysis = analyze_results(test_results)
    html_content = build_html_report(analysis, opts)

    case File.write(output_path, html_content) do
      :ok ->
        if opts[:open_browser] do
          System.cmd("open", [output_path], env: [])
        end

        :ok

      error ->
        error
    end
  end

  @doc """
  Generates a trend report comparing multiple test runs.
  """
  @spec generate_trend_report([{DateTime.t(), [test_result()]}], String.t(), report_options()) ::
          :ok | {:error, term()}
  def generate_trend_report(test_runs, output_path, opts \\ []) do
    trend_data = analyze_trends(test_runs)
    html_content = build_trend_report(trend_data, opts)

    File.write(output_path, html_content)
  end

  # Private functions

  defp analyze_results(test_results) do
    %{
      summary: build_summary(test_results),
      tier_distribution: calculate_tier_distribution(test_results),
      bottlenecks: find_bottlenecks(test_results),
      timeline: build_timeline(test_results),
      resource_usage: analyze_resource_usage(test_results)
    }
  end

  defp build_html_report(analysis, _opts) do
    """
    <!DOCTYPE html>
    <html>
    <head>
        <title>Arbor Test Performance Report</title>
        <meta charset="utf-8">
        <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
        <style>
            #{css_styles()}
        </style>
    </head>
    <body>
        <div class="container">
            <header>
                <h1>Arbor Test Performance Report</h1>
                <p class="timestamp">Generated: #{DateTime.utc_now() |> DateTime.to_string()}</p>
            </header>
            
            #{render_summary(analysis.summary)}
            #{render_tier_distribution(analysis.tier_distribution)}
            #{render_timeline(analysis.timeline)}
            #{render_bottlenecks(analysis.bottlenecks)}
            #{render_resource_usage(analysis.resource_usage)}
        </div>
        
        <script>
            #{javascript_code(analysis)}
        </script>
    </body>
    </html>
    """
  end

  defp css_styles do
    """
    body {
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        margin: 0;
        padding: 0;
        background: #f5f5f5;
    }

    .container {
        max-width: 1200px;
        margin: 0 auto;
        padding: 20px;
    }

    header {
        background: white;
        padding: 30px;
        border-radius: 10px;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        margin-bottom: 30px;
    }

    h1 {
        margin: 0;
        color: #333;
    }

    .timestamp {
        color: #666;
        margin-top: 10px;
    }

    .card {
        background: white;
        padding: 20px;
        border-radius: 10px;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        margin-bottom: 20px;
    }

    .stats-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
        gap: 20px;
        margin-bottom: 30px;
    }

    .stat-card {
        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
        color: white;
        padding: 20px;
        border-radius: 10px;
        text-align: center;
    }

    .stat-value {
        font-size: 2em;
        font-weight: bold;
        margin: 10px 0;
    }

    .stat-label {
        opacity: 0.9;
    }

    .chart-container {
        position: relative;
        height: 400px;
        margin: 20px 0;
    }

    .bottleneck-list {
        max-height: 500px;
        overflow-y: auto;
    }

    .bottleneck-item {
        padding: 15px;
        border-bottom: 1px solid #eee;
        display: flex;
        justify-content: space-between;
        align-items: center;
    }

    .bottleneck-item:hover {
        background: #f9f9f9;
    }

    .duration-bar {
        height: 4px;
        background: #e0e0e0;
        border-radius: 2px;
        margin-top: 5px;
        position: relative;
    }

    .duration-fill {
        height: 100%;
        background: linear-gradient(90deg, #4CAF50 0%, #FFC107 50%, #F44336 100%);
        border-radius: 2px;
        transition: width 0.3s ease;
    }

    .tag {
        display: inline-block;
        padding: 4px 8px;
        border-radius: 4px;
        font-size: 0.8em;
        margin-left: 10px;
    }

    .tag-fast { background: #4CAF50; color: white; }
    .tag-contract { background: #2196F3; color: white; }
    .tag-integration { background: #FF9800; color: white; }
    .tag-distributed { background: #9C27B0; color: white; }
    .tag-chaos { background: #F44336; color: white; }
    """
  end

  defp javascript_code(analysis) do
    """
    // Tier Distribution Pie Chart
    const tierCtx = document.getElementById('tierChart').getContext('2d');
    new Chart(tierCtx, {
        type: 'doughnut',
        data: {
            labels: #{Jason.encode!(Map.keys(analysis.tier_distribution))},
            datasets: [{
                data: #{Jason.encode!(Enum.map(analysis.tier_distribution, fn {_, v} -> v.count end))},
                backgroundColor: ['#4CAF50', '#2196F3', '#FF9800', '#9C27B0', '#F44336']
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: {
                    position: 'bottom'
                }
            }
        }
    });

    // Timeline Chart
    const timelineCtx = document.getElementById('timelineChart').getContext('2d');
    new Chart(timelineCtx, {
        type: 'scatter',
        data: {
            datasets: [{
                label: 'Test Execution Timeline',
                data: #{Jason.encode!(format_timeline_data(analysis.timeline))},
                backgroundColor: 'rgba(54, 162, 235, 0.5)'
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            scales: {
                x: {
                    type: 'linear',
                    position: 'bottom',
                    title: {
                        display: true,
                        text: 'Time (ms)'
                    }
                },
                y: {
                    title: {
                        display: true,
                        text: 'Duration (ms)'
                    }
                }
            }
        }
    });

    // Resource Usage Chart
    const resourceCtx = document.getElementById('resourceChart').getContext('2d');
    new Chart(resourceCtx, {
        type: 'line',
        data: {
            labels: #{Jason.encode!(Enum.map(analysis.resource_usage, & &1.label))},
            datasets: [{
                label: 'Memory Usage (MB)',
                data: #{Jason.encode!(Enum.map(analysis.resource_usage, & &1.memory_mb))},
                borderColor: 'rgb(255, 99, 132)',
                tension: 0.1
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false
        }
    });
    """
  end

  defp render_summary(summary) do
    """
    <div class="stats-grid">
        <div class="stat-card">
            <div class="stat-label">Total Tests</div>
            <div class="stat-value">#{summary.total_tests}</div>
        </div>
        <div class="stat-card">
            <div class="stat-label">Total Duration</div>
            <div class="stat-value">#{format_duration(summary.total_duration_ms)}</div>
        </div>
        <div class="stat-card">
            <div class="stat-label">Average Duration</div>
            <div class="stat-value">#{format_duration(summary.avg_duration_ms)}</div>
        </div>
        <div class="stat-card">
            <div class="stat-label">Success Rate</div>
            <div class="stat-value">#{Float.round(summary.success_rate * 100, 1)}%</div>
        </div>
    </div>
    """
  end

  defp render_tier_distribution(_distribution) do
    """
    <div class="card">
        <h2>Test Tier Distribution</h2>
        <div class="chart-container">
            <canvas id="tierChart"></canvas>
        </div>
    </div>
    """
  end

  defp render_timeline(_timeline) do
    """
    <div class="card">
        <h2>Test Execution Timeline</h2>
        <div class="chart-container">
            <canvas id="timelineChart"></canvas>
        </div>
    </div>
    """
  end

  defp render_bottlenecks(bottlenecks) do
    """
    <div class="card">
        <h2>Performance Bottlenecks</h2>
        <div class="bottleneck-list">
            #{Enum.map_join(bottlenecks, "\n", &render_bottleneck_item/1)}
        </div>
    </div>
    """
  end

  defp render_bottleneck_item(test) do
    """
    <div class="bottleneck-item">
        <div>
            <strong>#{test.name}</strong>
            <span class="tag tag-#{test.tier}">#{test.tier}</span>
            <div style="color: #666; font-size: 0.9em;">#{test.module}</div>
            <div class="duration-bar">
                <div class="duration-fill" style="width: #{custom_min(100, test.duration_ms / 10)}%"></div>
            </div>
        </div>
        <div style="text-align: right;">
            <strong>#{format_duration(test.duration_ms)}</strong>
            <div style="color: #666; font-size: 0.9em;">#{test.memory_mb}MB</div>
        </div>
    </div>
    """
  end

  defp render_resource_usage(_usage) do
    """
    <div class="card">
        <h2>Resource Usage</h2>
        <div class="chart-container">
            <canvas id="resourceChart"></canvas>
        </div>
    </div>
    """
  end

  # Helper functions

  defp build_summary(test_results) do
    %{
      total_tests: length(test_results),
      total_duration_ms: Enum.sum(Enum.map(test_results, & &1.duration_ms)),
      avg_duration_ms: calculate_average(Enum.map(test_results, & &1.duration_ms)),
      success_rate: calculate_success_rate(test_results)
    }
  end

  defp calculate_tier_distribution(test_results) do
    test_results
    |> Enum.group_by(& &1.tier)
    |> Map.new(fn {tier, tests} ->
      {tier,
       %{
         count: length(tests),
         total_duration: Enum.sum(Enum.map(tests, & &1.duration_ms))
       }}
    end)
  end

  defp find_bottlenecks(test_results) do
    test_results
    |> Enum.sort_by(& &1.duration_ms, :desc)
    |> Enum.take(20)
  end

  defp build_timeline(test_results) do
    test_results
    |> Enum.sort_by(& &1.start_time)
    |> Enum.map(fn test ->
      %{
        name: test.name,
        start: test.start_time,
        duration: test.duration_ms
      }
    end)
  end

  defp analyze_resource_usage(test_results) do
    test_results
    |> Enum.sort_by(& &1.start_time)
    |> Enum.map(fn test ->
      %{
        label: test.name,
        memory_mb: test.memory_mb,
        process_count: test.process_count
      }
    end)
  end

  defp analyze_trends(test_runs) do
    test_runs
    |> Enum.map(fn {timestamp, results} ->
      %{
        timestamp: timestamp,
        summary: build_summary(results),
        bottleneck_count: length(find_bottlenecks(results))
      }
    end)
  end

  defp build_trend_report(_trend_data, _opts) do
    # Simplified - would build full trend report
    "<html><body>Trend Report</body></html>"
  end

  defp format_timeline_data(timeline) do
    timeline
    |> Enum.map(fn item ->
      %{x: item.start, y: item.duration}
    end)
  end

  defp calculate_average(values) do
    case length(values) do
      0 -> 0
      n -> Enum.sum(values) / n
    end
  end

  defp calculate_success_rate(test_results) do
    passed = Enum.count(test_results, &(&1.status == :passed))
    total = length(test_results)
    if total > 0, do: passed / total, else: 1.0
  end

  defp format_duration(ms) when ms < 1000, do: "#{round(ms)}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp custom_min(a, b) when a < b, do: a
  defp custom_min(_, b), do: b
end
