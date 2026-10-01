# Usage

## Callback contract

Periodical accepts only exported module-function-arguments callbacks. The
callback arity is the supplied argument count plus one because the first
argument is always a `Periodical.Trigger`:

```elixir
defmodule MyApp.Refresh do
  def run(%Periodical.Trigger{} = trigger, cache) do
    MyApp.Cache.refresh(cache, scheduled_at: trigger.scheduled_at)
  end
end
```

This release intentionally removes anonymous-function and ambiguous positional
legacy APIs. MFA registrations are release-safe and have a stable validation
contract.

## Recurring schedules

Pass either a `Periodical.Recurrence` or an RFC 5545 `RRULE` expression:

```elixir
{:ok, id} =
  Periodical.every("FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=30;BYSECOND=0", MyApp.Report, :build, [:weekly],
    name: :weekly_report,
    overlap: :skip,
    misfire: :fire_once,
    execution_timeout_ms: 120_000,
    time_zone: "Etc/UTC"
  )
```

Recurring cadence is anchored to the previous scheduled occurrence. A late
callback does not shift every future occurrence. When time has advanced past
the next anchored occurrence, Periodical calculates the first future
occurrence and does not run an unbounded catch-up loop.

## One-time schedules

The instant must be a `DateTime` strictly in the future:

```elixir
run_at = DateTime.add(DateTime.utc_now(), 300, :second)
{:ok, id} = Periodical.once(run_at, MyApp.Export, :run, [:daily])
```

One-time schedules leave the registry after completion, failure, timeout,
cancellation, or a skipped terminal occurrence.

## Options

| Option | Values | Default | Purpose |
| --- | --- | --- | --- |
| `:name` | atom, bounded tuple, or `nil` | `nil` | Unique live schedule reference |
| `:overlap` | `:skip` or `:allow` | configured `:skip` | Whether occurrences of one schedule may run concurrently |
| `:misfire` | `:skip` or `:fire_once` | configured `:skip` | Whether one blocked occurrence is retained |
| `:execution_timeout_ms` | positive integer | configured 60 seconds | Callback execution deadline |
| `:time_zone` | timezone binary | configured `Etc/UTC` | Recurrence calculation timezone |

`:fire_once` coalesces blocked work to at most one pending occurrence for a
schedule. It never creates an unbounded catch-up queue.

## Control and stats

```elixir
:ok = Periodical.pause(id)
:ok = Periodical.resume(id)
:ok = Periodical.cancel(id)

%Periodical.Stats{} = Periodical.stats()
```

IDs are local to the scheduler lifetime. A configured atom or bounded tuple
name can be used for control operations. Pausing removes future timers and
pending work but lets an already-running callback finish. Cancellation also
terminates running callbacks.

## Configuration

Stable instance-wide settings belong under `Periodical.Config`:

```elixir
config :periodical, Periodical.Config,
  max_schedules: 1_024,
  max_pending_triggers: 256,
  max_in_flight: 4,
  admission_timeout_ms: 5_000,
  default_execution_timeout_ms: 60_000,
  max_execution_timeout_ms: 3_600_000,
  shutdown_timeout_ms: 5_000,
  default_overlap: :skip,
  default_misfire: :skip,
  default_time_zone: "Etc/UTC",
  health_gate: nil
```

`clock_module` and `timer_module` are deterministic adapter boundaries intended
for tests and controlled runtime substitution. Configuration is validated
before the scheduler starts. Changing it requires an application restart.

## Optional health admission

Set `health_gate: :work` only when the consuming application includes and
configures a gate implementing `Periodical.Gate`. Periodical subscribes to
the gate; closed gates stop dispatch and apply each schedule's misfire policy.
Periodical does not register health resources or manipulate global startup
state. Startup fails if a configured gate dependency is absent or invalid.

## Graceful shutdown

Call `Periodical.drain/1` from the host application's shutdown orchestration
after closing its health admission gates:

```elixir
:ok = Periodical.drain(5_000)
```

Drain permanently rejects new schedules, stops pending occurrence dispatch,
and waits only for callbacks already running. It returns
`{:error, %Periodical.Error{code: :drain_timeout}}` if the deadline expires and
leaves registration closed. The host's overall termination grace period must
exceed this timeout. Registered schedules and pending occurrences do not
survive the subsequent application stop because Periodical is in-memory.

## Failure, retry, and shutdown behavior

- Callback results and exits are consumed by the scheduler.
- A callback exceeding its execution deadline is terminated and capacity is
  released.
- Periodical never retries a callback. Retry ownership belongs to the durable
  executor or application integration that can enforce idempotency.
- `shutdown_timeout_ms` is both the default explicit drain deadline and the
  scheduler supervisor's final termination bound. The host must call
  `Periodical.drain/1` before OTP child shutdown if accepted callbacks should
  receive that deadline to finish.
- Schedule, queue, and concurrency limits are per Periodical application
  instance, not global across replicas.

## Telemetry

Periodical emits canonical events beneath `[:periodical, ...]` for
registration, control, execution spans, terminal outcomes, skipped triggers,
lateness, and scheduler utilization. Metadata uses finite result, operation,
reason, and trigger-kind values. Reporters are attached at the deployable
composition boundary.

## Durable handoff

Keep the schedule local and make the callback small:

```elixir
def enqueue(%Periodical.Trigger{} = trigger, job) do
  MyApp.DurableQueue.enqueue(job,
    idempotency_key: {trigger.schedule_id, trigger.scheduled_at}
  )
end
```

The queue owns persistence, retries, redelivery, and distributed worker
coordination. Periodical owns only when the handoff should be attempted.
