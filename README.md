# Overview

Periodical is a bounded, in-memory scheduler for recurring and one-time MFA
callbacks in one BEAM instance. It owns schedule calculation, timers, callback
isolation, overlap and misfire policy, cancellation, and telemetry. It is not a
durable queue. Across several instances it can, optionally, run each named
schedule on just one of them.

## Responsibilities

- Own bounded local recurrence calculation, triggering, overlap/misfire policy, and callback lifecycle.
- Ask an optional, configured coordinator which instance runs a named schedule's occurrence.

## Non-responsibilities

- Retry ownership or durable delivery: a run that is lost (for example because
  the instance that claimed it died) is not run again.
- Claim storage: the coordinator adapter owns it (see
  [Cluster-wide coordination](#cluster-wide-coordination)).

## Features

- RFC 5545 `RRULE` recurrence expressions, the iCalendar standard.
- Exact future `DateTime` scheduling.
- Typed `Periodical.Trigger` callback context.
- Configured bounds for schedules, pending triggers, concurrent callbacks, and
  callback execution time.
- Pause, resume, cancellation, unique names, and count-only utilization stats.
- Optional admission gating through any module implementing `Periodical.Gate`.
- Optional cluster-wide coordination through any module implementing
  `Periodical.Coordinator`, with ready-made Redis/KeyDB and Ecto adapters.
- Bounded `Periodical.drain/1` shutdown waiting for active callbacks.
- Canonical `[:periodical, ...]` telemetry, emitted through `:telemetry`.

## Installation

```elixir
def deps do
  [
    {:periodical, "~> 0.2"}
  ]
end
```

Periodical is an OTP application because it owns timers, scheduler state, and
supervised callbacks. Adding it as a normal runtime dependency starts that
runtime automatically.

## First schedule

Callbacks are exported MFA functions and receive a `Periodical.Trigger` before
the supplied arguments:

```elixir
defmodule MyApp.Cleanup do
  def run(%Periodical.Trigger{} = trigger, scope) do
    MyApp.Log.cleanup_started(trigger.schedule_id, scope)
    :ok
  end
end

{:ok, schedule_id} =
  Periodical.every("FREQ=MINUTELY;INTERVAL=5", MyApp.Cleanup, :run, [:expired_sessions])
```

See [Usage](guides/usage.md) for policies and configuration and
[Examples](guides/examples.md) for focused patterns.

## Durability boundary

Schedules and pending triggers disappear when the local application stops.
Without a coordinator, multiple replicas each run their own schedules. For
durable or retryable work, make the Periodical callback publish an idempotent
job to the application-owned queue or messaging library.

## Cluster-wide coordination

When several instances register the same schedule and it should run on only
one of them per occurrence, configure a coordinator and name the schedule:

```elixir
# mix.exs
{:periodical_redis, "~> 0.1"}   # Redis or KeyDB
# or
{:periodical_ecto, "~> 0.1"}    # PostgreSQL or MariaDB/MySQL

# config/runtime.exs
config :periodical, Periodical.Config,
  coordinator: {PeriodicalRedis, connection: MyApp.Redix}

Periodical.every("FREQ=MINUTELY;INTERVAL=5", MyApp.Cleanup, :run, [], name: :cleanup)
```

Each instance claims the run in a shared store; the winner holds a lease that
covers this occurrence on every instance, whatever their clock skew or
registration times, and the others skip it. Periodical itself gains no
dependency. See [Usage](guides/usage.md#cluster-wide-coordination) and
`Periodical.Coordinator`.

## License

Apache License 2.0; see [LICENSE](LICENSE).

## Name origin

“Periodical” is a direct functional name: something that occurs at recurring
intervals. It fits the library's responsibility for calculating and triggering
local recurring work.
