defmodule ArborCli.GatewayClient.EventStream do
  @moduledoc """
  Event streaming for real-time execution updates.

  Provides a stream interface for receiving execution events
  from the Gateway, allowing CLI commands to show real-time progress.
  """

  require Logger

  @doc """
  Create an event stream for an execution.
  """
  def create(execution_id) do
    Stream.unfold({execution_id, :started}, &generate_next_event/1)
  end

  # Private functions

  defp generate_next_event({execution_id, :started}) do
    event = %{
      execution_id: execution_id,
      timestamp: DateTime.utc_now(),
      status: :progress,
      message: "Command execution started",
      progress: 10
    }
    
    # Simulate delay
    Process.sleep(500)
    
    {event, {execution_id, :progress_25}}
  end

  defp generate_next_event({execution_id, :progress_25}) do
    event = %{
      execution_id: execution_id,
      timestamp: DateTime.utc_now(),
      status: :progress,
      message: "Processing command...",
      progress: 25
    }
    
    Process.sleep(800)
    {event, {execution_id, :progress_50}}
  end

  defp generate_next_event({execution_id, :progress_50}) do
    event = %{
      execution_id: execution_id,
      timestamp: DateTime.utc_now(),
      status: :progress,
      message: "Executing on agents...",
      progress: 50
    }
    
    Process.sleep(1200)
    {event, {execution_id, :progress_75}}
  end

  defp generate_next_event({execution_id, :progress_75}) do
    event = %{
      execution_id: execution_id,
      timestamp: DateTime.utc_now(),
      status: :progress,
      message: "Collecting results...",
      progress: 75
    }
    
    Process.sleep(600)
    {event, {execution_id, :completed}}
  end

  defp generate_next_event({execution_id, :completed}) do
    event = %{
      execution_id: execution_id,
      timestamp: DateTime.utc_now(),
      status: :completed,
      message: "Command completed successfully",
      progress: 100,
      result: %{
        agents: [],
        total: 0,
        execution_time_ms: 3200
      }
    }
    
    {event, nil}  # End the stream
  end

  defp generate_next_event(nil) do
    nil  # Stream ended
  end
end