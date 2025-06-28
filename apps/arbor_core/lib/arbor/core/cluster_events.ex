defmodule Arbor.Core.ClusterEvents do
  @moduledoc """
  Cluster-wide event broadcasting using Phoenix.PubSub.

  This module provides a centralized way to broadcast and listen to
  agent lifecycle events across the entire cluster. Events are automatically
  distributed to all connected nodes.

  ## Event Types

  - `:agent_started` - Agent successfully started
  - `:agent_stopped` - Agent stopped gracefully
  - `:agent_failed` - Agent process crashed/failed
  - `:agent_restarted` - Agent restarted after failure
  - `:agent_migrated` - Agent moved to different node
  - `:agent_reconciled` - Agent reconciliation completed
  - `:cluster_node_joined` - New node joined the cluster
  - `:cluster_node_left` - Node left/disconnected from cluster

  ## Usage

      # Subscribe to all agent events
      ClusterEvents.subscribe(:agent_events)

      # Subscribe to specific agent events
      ClusterEvents.subscribe(:agent_events, agent_id: "my-agent")

      # Subscribe to cluster topology events
      ClusterEvents.subscribe(:cluster_events)

      # Broadcast an event
      ClusterEvents.broadcast(:agent_started, %{
        agent_id: "agent-123",
        node: node(),
        pid: self()
      })

  ## Event Data Format

  All events include:
  - `:event_type` - The type of event
  - `:timestamp` - When the event occurred (milliseconds)
  - `:node` - Node where the event originated
  - `:cluster_id` - Unique cluster identifier

  Agent events also include:
  - `:agent_id` - Agent identifier
  - `:pid` - Process ID (when applicable)
  - Additional event-specific data
  """

  @behaviour Arbor.Contracts.Cluster.Events

  alias Phoenix.PubSub
  require Logger

  @pubsub_name Arbor.Core.PubSub

  # Service lifecycle callbacks

  @impl true
  def start_service(_config) do
    # ClusterEvents is started as part of the PubSub supervision tree
    # This callback is for compatibility with the contract
    {:ok, self()}
  end

  @impl true
  def stop_service(_reason) do
    # ClusterEvents is stopped as part of the PubSub supervision tree
    # This callback is for compatibility with the contract
    :ok
  end

  @impl true
  def get_status do
    # Return the status of the cluster events service
    {:ok, %{status: :healthy, pubsub: @pubsub_name}}
  end

  # Topic names
  @agent_events_topic "agent_events"
  @cluster_events_topic "cluster_events"
  @reconciliation_events_topic "reconciliation_events"

  @type event_type ::
          :agent_started
          | :agent_stopped
          | :agent_failed
          | :agent_restarted
          | :agent_migrated
          | :agent_reconciled
          | :cluster_node_joined
          | :cluster_node_left
          | :reconciliation_started
          | :reconciliation_completed
          | :reconciliation_failed

  @type event_data :: map()
  @type subscription_options :: [agent_id: String.t()] | []

  @doc """
  Subscribe to cluster events.

  ## Topics

  - `:agent_events` - All agent lifecycle events
  - `:cluster_events` - Cluster topology changes
  - `:reconciliation_events` - Reconciliation process events

  ## Options

  - `agent_id: "agent-123"` - Only receive events for specific agent
  """
  @spec subscribe(atom(), subscription_options()) :: :ok | {:error, term()}
  def subscribe(topic_type, opts \\ [])

  def subscribe(:agent_events, opts) do
    topic =
      if agent_id = Keyword.get(opts, :agent_id) do
        "#{@agent_events_topic}:#{agent_id}"
      else
        @agent_events_topic
      end

    PubSub.subscribe(@pubsub_name, topic)
  end

  def subscribe(:cluster_events, _opts) do
    PubSub.subscribe(@pubsub_name, @cluster_events_topic)
  end

  def subscribe(:reconciliation_events, _opts) do
    PubSub.subscribe(@pubsub_name, @reconciliation_events_topic)
  end

  def subscribe(topic_type, _opts) do
    Logger.warning("Unknown subscription topic: #{inspect(topic_type)}")
    {:error, :unknown_topic}
  end

  @doc """
  Unsubscribe from cluster events.
  """
  @spec unsubscribe(atom(), subscription_options()) :: :ok
  def unsubscribe(topic_type, opts \\ [])

  def unsubscribe(:agent_events, opts) do
    topic =
      if agent_id = Keyword.get(opts, :agent_id) do
        "#{@agent_events_topic}:#{agent_id}"
      else
        @agent_events_topic
      end

    PubSub.unsubscribe(@pubsub_name, topic)
  end

  def unsubscribe(:cluster_events, _opts) do
    PubSub.unsubscribe(@pubsub_name, @cluster_events_topic)
  end

  def unsubscribe(:reconciliation_events, _opts) do
    PubSub.unsubscribe(@pubsub_name, @reconciliation_events_topic)
  end

  @doc """
  Broadcast an event to all subscribers across the cluster.

  Events are automatically enriched with timestamp, node, and cluster metadata.
  """
  @spec broadcast(event_type(), event_data()) :: :ok | {:error, term()}
  def broadcast(event_type, event_data \\ %{})

  # Agent events
  def broadcast(event_type, %{agent_id: agent_id} = event_data)
      when event_type in [
             :agent_started,
             :agent_stopped,
             :agent_failed,
             :agent_restarted,
             :agent_migrated,
             :agent_reconciled
           ] do
    enriched_event = enrich_event(event_type, event_data)

    # Broadcast to general agent events topic
    PubSub.broadcast(
      @pubsub_name,
      @agent_events_topic,
      {:cluster_event, event_type, enriched_event}
    )

    # Broadcast to agent-specific topic
    agent_topic = "#{@agent_events_topic}:#{agent_id}"
    PubSub.broadcast(@pubsub_name, agent_topic, {:cluster_event, event_type, enriched_event})

    emit_telemetry(event_type, enriched_event)
    :ok
  end

  # Cluster topology events
  def broadcast(event_type, event_data)
      when event_type in [:cluster_node_joined, :cluster_node_left] do
    enriched_event = enrich_event(event_type, event_data)

    PubSub.broadcast(
      @pubsub_name,
      @cluster_events_topic,
      {:cluster_event, event_type, enriched_event}
    )

    emit_telemetry(event_type, enriched_event)
    :ok
  end

  # Reconciliation events
  def broadcast(event_type, event_data)
      when event_type in [
             :reconciliation_started,
             :reconciliation_completed,
             :reconciliation_failed
           ] do
    enriched_event = enrich_event(event_type, event_data)

    PubSub.broadcast(
      @pubsub_name,
      @reconciliation_events_topic,
      {:cluster_event, event_type, enriched_event}
    )

    emit_telemetry(event_type, enriched_event)
    :ok
  end

  def broadcast(event_type, _event_data) do
    Logger.warning("Unknown event type for broadcast: #{inspect(event_type)}")
    {:error, :unknown_event_type}
  end

  @doc false
  @deprecated "Phoenix.PubSub doesn't expose subscriber counts. This function is not implemented."
  @spec subscriber_count(atom()) :: non_neg_integer()
  def subscriber_count(_topic_type) do
    # Phoenix.PubSub doesn't expose subscriber count
    # This is a placeholder function that always returns 0
    # If subscriber metrics become critical, implement custom tracking
    0
  end

  @doc false
  @deprecated "This function returns static topic names without real subscriber counts."
  @spec list_active_topics() :: %{String.t() => non_neg_integer()}
  def list_active_topics do
    # Returns static topic names with placeholder counts
    # Phoenix.PubSub doesn't expose real subscriber information
    %{
      @agent_events_topic => 0,
      @cluster_events_topic => 0,
      @reconciliation_events_topic => 0
    }
  end

  @doc """
  Get cluster event broadcasting statistics.
  """
  @spec get_stats() :: %{
          active_topics: %{binary() => non_neg_integer()},
          node: node(),
          cluster_id: binary(),
          pubsub_name: atom()
        }
  def get_stats do
    %{
      active_topics: list_active_topics(),
      node: node(),
      cluster_id: get_cluster_id(),
      pubsub_name: @pubsub_name
    }
  end

  # Private helpers

  @spec enrich_event(event_type(), event_data()) :: event_data()
  defp enrich_event(event_type, event_data) do
    Map.merge(event_data, %{
      event_type: event_type,
      timestamp: System.system_time(:millisecond),
      node: node(),
      cluster_id: get_cluster_id()
    })
  end

  @spec get_cluster_id() :: String.t()
  defp get_cluster_id do
    # Try to get cluster_id from application config first
    case Application.get_env(:arbor_core, :cluster_id) do
      nil ->
        # Fall back to node cookie for development/testing
        # In production, :cluster_id should be explicitly configured
        Node.get_cookie() |> to_string() |> String.slice(0, 8)

      cluster_id ->
        cluster_id
    end
  end

  @spec emit_telemetry(event_type(), event_data()) :: :ok
  defp emit_telemetry(event_type, event_data) do
    :telemetry.execute(
      [:arbor, :cluster_events, :broadcast],
      %{
        event_count: 1
      },
      %{
        event_type: event_type,
        node: node(),
        agent_id: Map.get(event_data, :agent_id),
        topic_count: map_size(list_active_topics())
      }
    )
  end
end
