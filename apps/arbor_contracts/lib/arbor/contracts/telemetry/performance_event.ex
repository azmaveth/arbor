defmodule Arbor.Contracts.Telemetry.PerformanceEvent do
  @moduledoc """
  Defines contracts for general-purpose performance telemetry events.

  This contract is used for emitting metrics related to timing, resource
  consumption, and other performance indicators that are not specific to
  agents or reconciliation.
  """

  @behaviour Arbor.Contracts.Telemetry.Event

  alias Arbor.Contracts.Telemetry.Event

  @typedoc "A performance metric event."
  @type t :: %__MODULE__.Metric{}

  defmodule Metric do
    @moduledoc "A generic performance metric."
    @type t :: %__MODULE__{
            event_name: list(atom()),
            measurements: %{:value => number()},
            metadata: %{
              :node => atom(),
              optional(any()) => any()
            },
            timestamp: integer()
          }

    defstruct event_name: [],
              measurements: %{},
              metadata: %{},
              timestamp: nil
  end

  @doc """
  Validates a given performance event against its contract.
  """
  @impl Event
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__.Metric{} = event) do
    with :ok <- Event.validate(event),
         true <- Map.has_key?(event.measurements, :value),
         true <- is_number(event.measurements.value),
         true <- Map.has_key?(event.metadata, :node) do
      :ok
    else
      _ -> {:error, :invalid_performance_metric_event}
    end
  end

  def validate(_other) do
    {:error, :unknown_performance_event_type}
  end
end
