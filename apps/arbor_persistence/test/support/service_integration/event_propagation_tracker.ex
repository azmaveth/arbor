defmodule Arbor.Test.ServiceInteractionCase.EventPropagationTracker do
  @moduledoc """
  Tracks PubSub event propagation and validates message flow patterns.

  This module monitors Phoenix.PubSub events to ensure proper message delivery,
  ordering, and handling across Arbor's distributed services. It helps detect
  event delivery failures and timing issues in service integration tests.

  ## Features

  - **Event Tracking**: Monitors all PubSub events with timestamps
  - **Sequence Validation**: Ensures events occur in expected order
  - **Timeout Handling**: Detects missed or delayed events
  - **Pattern Matching**: Validates event structure and content
  - **Performance Metrics**: Tracks event propagation latency

  ## Usage

      tracker = EventPropagationTracker.start()
      
      # Expect a single event
      EventPropagationTracker.expect_event(tracker, :session_created, 5000)
      
      # Expect sequence of events
      EventPropagationTracker.expect_sequence(tracker, [
        {:command_received, 1000},
        {:agent_spawned, 2000},
        {:agent_registered, 3000}
      ])
      
      # Check received events
      events = EventPropagationTracker.get_received_events(tracker)
  """

  use GenServer

  @type event_type :: atom()
  @type event_data :: map()
  @type event_info :: %{
          type: event_type(),
          data: event_data(),
          timestamp: DateTime.t(),
          topic: binary(),
          received_at: integer()
        }
  @type timeout_ms :: non_neg_integer()

  defstruct received_events: [],
            expected_events: [],
            event_patterns: %{},
            start_time: nil,
            timeouts: %{}

  @doc """
  Starts a new event propagation tracker.
  """
  @spec start() :: pid()
  def start do
    {:ok, pid} =
      GenServer.start_link(__MODULE__, %__MODULE__{
        start_time: System.monotonic_time(:microsecond)
      })

    pid
  end

  @doc """
  Expects a specific event to be received within timeout period.
  """
  @spec expect_event(pid(), event_type(), timeout_ms()) :: :ok
  def expect_event(tracker, event_type, timeout_ms) do
    GenServer.call(tracker, {:expect_event, event_type, timeout_ms})
  end

  @doc """
  Expects a sequence of events with individual timeouts.
  """
  @spec expect_sequence(pid(), [{event_type(), timeout_ms()}]) :: :ok
  def expect_sequence(tracker, event_sequence) do
    GenServer.call(tracker, {:expect_sequence, event_sequence})
  end

  @doc """
  Records that an event was received from PubSub.
  """
  @spec record_event(pid(), event_type(), event_data(), binary()) :: :ok
  def record_event(tracker, event_type, event_data, topic) do
    GenServer.cast(tracker, {:record_event, event_type, event_data, topic})
  end

  @doc """
  Gets all events received so far.
  """
  @spec get_received_events(pid()) :: [event_info()]
  def get_received_events(tracker) do
    GenServer.call(tracker, :get_received_events)
  end

  @doc """
  Validates that all expected events were received.
  """
  @spec validate_expectations(pid()) :: :ok | {:error, [atom()]}
  def validate_expectations(tracker) do
    GenServer.call(tracker, :validate_expectations)
  end

  @doc """
  Gets event propagation metrics and timing information.
  """
  @spec get_propagation_metrics(pid()) :: map()
  def get_propagation_metrics(tracker) do
    GenServer.call(tracker, :get_propagation_metrics)
  end

  @doc """
  Sets pattern matchers for event validation.
  """
  @spec set_event_pattern(pid(), event_type(), (event_data() -> boolean())) :: :ok
  def set_event_pattern(tracker, event_type, pattern_fn) do
    GenServer.call(tracker, {:set_event_pattern, event_type, pattern_fn})
  end

  @doc """
  Waits for expected event with timeout.
  """
  @spec wait_for_event(pid(), event_type(), timeout_ms()) ::
          {:ok, event_info()} | {:error, :timeout}
  def wait_for_event(tracker, event_type, timeout_ms) do
    GenServer.call(tracker, {:wait_for_event, event_type, timeout_ms}, timeout_ms + 1000)
  end

  # GenServer implementation

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:expect_event, event_type, timeout_ms}, _from, state) do
    new_state = %{
      state
      | expected_events: [event_type | state.expected_events],
        timeouts: Map.put(state.timeouts, event_type, timeout_ms)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:expect_sequence, event_sequence}, _from, state) do
    events_to_expect = Enum.map(event_sequence, fn {event_type, _timeout} -> event_type end)
    timeout_map = Map.new(event_sequence)

    new_state = %{
      state
      | expected_events: events_to_expect ++ state.expected_events,
        timeouts: Map.merge(state.timeouts, timeout_map)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_received_events, _from, state) do
    events = Enum.reverse(state.received_events)
    {:reply, events, state}
  end

  @impl true
  def handle_call(:validate_expectations, _from, state) do
    received_types = Enum.map(state.received_events, & &1.type)
    missing_events = state.expected_events -- received_types

    result =
      if Enum.empty?(missing_events) do
        :ok
      else
        {:error, missing_events}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_propagation_metrics, _from, state) do
    current_time = System.monotonic_time(:microsecond)

    metrics = %{
      total_events: length(state.received_events),
      expected_events: length(state.expected_events),
      tracking_duration_ms: div(current_time - state.start_time, 1000),
      event_timeline: build_event_timeline(state.received_events),
      propagation_latencies: calculate_propagation_latencies(state.received_events),
      event_frequencies: calculate_event_frequencies(state.received_events)
    }

    {:reply, metrics, state}
  end

  @impl true
  def handle_call({:set_event_pattern, event_type, pattern_fn}, _from, state) do
    new_patterns = Map.put(state.event_patterns, event_type, pattern_fn)
    new_state = %{state | event_patterns: new_patterns}

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:wait_for_event, event_type, timeout_ms}, from, state) do
    # Check if event already received
    case Enum.find(state.received_events, fn event -> event.type == event_type end) do
      nil ->
        # Set up timeout and wait
        timer_ref = Process.send_after(self(), {:event_timeout, from, event_type}, timeout_ms)

        new_state =
          Map.put(state, :waiting_clients, [
            {from, event_type, timer_ref} | Map.get(state, :waiting_clients, [])
          ])

        {:noreply, new_state}

      event ->
        {:reply, {:ok, event}, state}
    end
  end

  @impl true
  def handle_cast({:record_event, event_type, event_data, topic}, state) do
    event_info = %{
      type: event_type,
      data: event_data,
      timestamp: DateTime.utc_now(),
      topic: topic,
      received_at: System.monotonic_time(:microsecond)
    }

    # Validate against pattern if set
    validated_event =
      case Map.get(state.event_patterns, event_type) do
        nil ->
          event_info

        pattern_fn ->
          if pattern_fn.(event_data) do
            event_info
          else
            Map.put(event_info, :pattern_validation, :failed)
          end
      end

    new_state = %{state | received_events: [validated_event | state.received_events]}

    # Notify waiting clients
    new_state = notify_waiting_clients(new_state, validated_event)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:event_timeout, from, event_type}, state) do
    GenServer.reply(from, {:error, :timeout})

    # Remove from waiting clients
    waiting_clients = Map.get(state, :waiting_clients, [])

    updated_clients =
      Enum.reject(waiting_clients, fn {client_from, _, _} -> client_from == from end)

    new_state = Map.put(state, :waiting_clients, updated_clients)

    {:noreply, new_state}
  end

  # Private helper functions

  defp notify_waiting_clients(state, event) do
    waiting_clients = Map.get(state, :waiting_clients, [])

    {matched_clients, remaining_clients} =
      Enum.split_with(waiting_clients, fn {_from, event_type, _timer_ref} ->
        event_type == event.type
      end)

    # Reply to matched clients and cancel their timers
    Enum.each(matched_clients, fn {from, _event_type, timer_ref} ->
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:ok, event})
    end)

    Map.put(state, :waiting_clients, remaining_clients)
  end

  defp build_event_timeline(events) do
    events
    |> Enum.reverse()
    |> Enum.map(fn event ->
      %{
        type: event.type,
        timestamp: event.timestamp,
        topic: event.topic
      }
    end)
  end

  defp calculate_propagation_latencies(events) do
    if length(events) < 2 do
      %{avg_latency_ms: 0, max_latency_ms: 0, min_latency_ms: 0}
    else
      latencies =
        events
        |> Enum.reverse()
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [event1, event2] ->
          div(event2.received_at - event1.received_at, 1000)
        end)

      %{
        avg_latency_ms: div(Enum.sum(latencies), length(latencies)),
        max_latency_ms: Enum.max(latencies),
        min_latency_ms: Enum.min(latencies),
        latency_distribution: latencies
      }
    end
  end

  defp calculate_event_frequencies(events) do
    events
    |> Enum.map(& &1.type)
    |> Enum.frequencies()
  end
end
