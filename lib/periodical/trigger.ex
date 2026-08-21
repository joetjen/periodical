defmodule Periodical.Trigger do
  @moduledoc "Describes one bounded scheduled callback occurrence."

  @enforce_keys [:kind, :lateness_ms, :schedule_id, :scheduled_at, :triggered_at]
  defstruct @enforce_keys

  @typedoc "A local trigger delivered to a scheduled MFA callback."
  @type t :: %__MODULE__{
          kind: :once | :recurring,
          lateness_ms: non_neg_integer(),
          schedule_id: pos_integer(),
          scheduled_at: DateTime.t(),
          triggered_at: DateTime.t()
        }
end
