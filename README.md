# Overview

Periodical is a bounded, in-memory scheduler for recurring and one-time MFA
callbacks in one BEAM instance. It owns schedule calculation, timers, callback
isolation, overlap and misfire policy, cancellation, and telemetry. It is not a
durable queue or a cluster-wide singleton scheduler.

## Responsibilities

- Own bounded local recurrence calculation, triggering, overlap/misfire policy, and callback lifecycle.

## Non-responsibilities

- Claim persistence, retry ownership, durable delivery, or cluster-wide singleton scheduling.

## Features

- RFC 5545 `RRULE` recurrence expressions, the iCalendar standard.
- Exact future `DateTime` scheduling.
- Typed `Periodical.Trigger` callback context.
- Configured bounds for schedules, pending triggers, concurrent callbacks, and
  callback execution time.
- Pause, resume, cancellation, unique names, and count-only utilization stats.
- Optional admission gating through any module implementing `Periodical.Gate`.
- Bounded `Periodical.drain/1` shutdown waiting for active callbacks.
- Canonical `[:periodical, ...]` telemetry, emitted through `:telemetry`.

## Installation

```elixir
def deps do
  [
    {:periodical, "~> 2.0"}
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

See [Usage](USAGE_GUIDE.md) for policies and configuration and
[Examples](EXAMPLES.md) for focused patterns.

## Durability boundary

Schedules and pending triggers disappear when the local application stops.
Multiple replicas each run their own schedules. For durable, retryable, or
cluster-wide work, make the Periodical callback publish an idempotent job to the
workspace-owned queue or messaging library.

## Name origin

“Periodical” is a direct functional name: something that occurs at recurring
intervals. It fits the library's responsibility for calculating and triggering
local recurring work.
