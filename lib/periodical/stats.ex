defmodule Periodical.Stats do
  @moduledoc "A bounded count-only snapshot of Periodical runtime utilization."

  @enforce_keys [:in_flight, :paused, :pending, :schedule_capacity, :schedules]
  defstruct @enforce_keys

  @typedoc "Counts that contain no callback payloads or schedule identifiers."
  @type t :: %__MODULE__{
          in_flight: non_neg_integer(),
          paused: non_neg_integer(),
          pending: non_neg_integer(),
          schedule_capacity: pos_integer(),
          schedules: non_neg_integer()
        }
end
