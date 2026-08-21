# Examples

## Recurring expression

```elixir
Periodical.every("FREQ=SECONDLY;INTERVAL=30", MyApp.Presence, :expire, [])
```

## Calendar recurrence

```elixir
Periodical.every("FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=8;BYMINUTE=0;BYSECOND=0", MyApp.Invoice, :prepare, [],
  name: :monthly_invoices,
  time_zone: "Europe/Berlin"
)
```

## Recurrence struct

```elixir
{:ok, recurrence} = Periodical.Recurrence.parse("FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=30")
Periodical.every(recurrence, MyApp.Report, :build, [:weekly])
```

## One-time work

```elixir
run_at = DateTime.add(DateTime.utc_now(), 600, :second)
Periodical.once(run_at, MyApp.Expiry, :expire, [token_id])
```

## Typed callback

```elixir
defmodule MyApp.Report do
  def build(%Periodical.Trigger{} = trigger, kind) do
    MyApp.ReportStore.build(kind,
      occurrence: trigger.scheduled_at,
      lateness_ms: trigger.lateness_ms
    )
  end
end
```

## Pause, resume, and cancel

```elixir
{:ok, id} =
  Periodical.every("FREQ=HOURLY", MyApp.Refresh, :run, [], name: :refresh)

:ok = Periodical.pause(:refresh)
:ok = Periodical.resume(id)
:ok = Periodical.cancel(:refresh)
```

## Durable handoff

```elixir
defmodule MyApp.ScheduledHandoff do
  def publish(%Periodical.Trigger{} = trigger, job) do
    MyApp.Queue.enqueue(job,
      idempotency_key: {trigger.schedule_id, trigger.scheduled_at}
    )
  end
end

Periodical.every(
  "FREQ=MINUTELY;INTERVAL=5",
  MyApp.ScheduledHandoff,
  :publish,
  [%{type: :refresh_catalog}],
  name: :catalog_refresh,
  misfire: :fire_once,
  overlap: :skip
)
```

This combined pattern keeps time calculation local while assigning durability,
retry, and cross-replica coordination to the queue that owns those guarantees.
