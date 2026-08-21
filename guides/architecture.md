# Architecture

`periodical` is a runtime-capable **Library** that owns one bounded, node-local,
in-memory scheduler for recurring and one-time MFA callbacks. It calculates
occurrences, owns timers and schedule state, applies overlap and misfire policy,
and executes callbacks in a supervised task pool. It has no independent image
or deployment.

## Responsibility and boundaries

Periodical decides when a local handoff should be attempted. It does not own
durability, retries, cluster-wide singleton execution, or cross-node schedule
coordination. Every BEAM instance has an independent schedule registry and
runs the same registered schedules. Durable or exactly-coordinated work must be
published by the callback to a source-owning broker or queue.

The OTP application is justified because the library owns long-lived scheduler
and worker-supervisor processes. Recurrence parsing and calendar calculation
remain in `Periodical.Recurrence`; Periodical wraps those values in schedules
and owns runtime triggering. The optional health library owns gate state.

## Code map

| Path | Purpose |
| --- | --- |
| `lib/periodical.ex` | Public recurring/one-time registration and lifecycle control. |
| `lib/periodical/application.ex` | Configuration validation and root supervision startup. |
| `lib/periodical/config.ex` | Typed operational defaults, adapters, and validation. |
| `lib/periodical/schedule.ex` | Passive recurrence/one-time calculations using explicit reference time. |
| `lib/periodical/job.ex` | Internal validated registration and callback metadata. |
| `lib/periodical/scheduler.ex` | Schedule, timer, pending-trigger, and callback state machine. |
| `lib/periodical/clock.ex` | Replaceable wall-clock behavior and system implementation. |
| `lib/periodical/timer.ex` | Replaceable one-shot timer behaviour over Erlang's `:timer`. |
| `lib/periodical/trigger.ex` | Typed callback occurrence value. |
| `lib/periodical/stats.ex` | Payload-free public utilization snapshot. |
| `lib/periodical/telemetry.ex` | Canonical `[:periodical, ...]` declarations. |
| `test/periodical/` | Offline unit, property, lifecycle, and package tests. |
| `test/fixtures/consumer_app/` | Test-only application proving dependency startup and callback delivery. |

## Runtime and startup

```text
Periodical.Supervisor (:rest_for_one)
├── Periodical.TaskSupervisor (Task.Supervisor, max_children: max_in_flight)
└── Periodical.Scheduler (GenServer, shutdown: shutdown_timeout_ms)
```

The task supervisor starts first. Under `:rest_for_one`, replacing it also
replaces the scheduler so scheduler state cannot retain task references owned
by an earlier worker supervisor. A scheduler-only failure loses all in-memory
schedules; that is part of the explicit non-durable contract.


## Application startup call flow

OTP starts the following application callbacks in dependency/release order. Each callback must return only after its root supervisor or bounded startup work succeeds:

1. OTP invokes **Periodical.Application.start/2** in `libs/periodical/lib/periodical/application.ex`. It calls **Config.load/0** → **Supervisor.start_link/2** → **children/1** → **supervisor_options/0**.

The callback and its startup/shutdown helpers have this source-derived flow:

| Entry point or callback | Visibility | Direct call flow |
| --- | --- | --- |
| **start/2** | `def` | calls **Config.load/0** → **Supervisor.start_link/2** → **children/1** → **supervisor_options/0**; references **Config**, **Supervisor** |
| **children/1** | `defp` | calls **Supervisor.child_spec/2** → **Config.max_in_flight/1** → **Config.shutdown_timeout_ms/1**; references **Supervisor**, **Task.Supervisor**, **Periodical.TaskSupervisor**, **Config**, **Scheduler** |
| **supervisor_options/0** | `defp` | performs no further named function call in its body; references **Periodical.Supervisor** |

The project-owned runtime process set is **Periodical.Scheduler**. Exact child order and option-dependent children are defined by the `start/2` and supervisor `init/1` flows below; dependency-owned processes remain documented by their owning libraries.

## Process call flows

### **Periodical.Scheduler**

- **OTP abstraction:** `GenServer` implemented in `libs/periodical/lib/periodical/scheduler.ex`.
- **Owner and restart:** started from **Periodical.Application**. Unless its child specification overrides this, OTP uses the abstraction's standard permanent-child restart behavior.
- **Registration and lookup:** the concrete `start_link` flow below is authoritative for a local name, Registry/via tuple, or caller-supplied name; no undocumented global lookup is assumed.
- **State and resources:** `init` and `handle_continue` rows show the functions used to construct state and acquire resources. External dependency processes are not re-owned by this module.
- **Failure and shutdown:** callback crashes are returned to the supervising owner. A listed `terminate` flow performs explicit cleanup; otherwise OTP and resource owners perform their standard teardown.

| Entry point or callback | Visibility | Direct call flow |
| --- | --- | --- |
| **start_link/1** | `def` | calls **GenServer.start_link/3**; references **GenServer** |
| **init/1** | `def` | calls **subscribe_gate/1** → **Config.health_gate/1** → **initial_state/2**; references **Config** |
| **handle_call/3** | `def` | calls **register/6** → **emit_utilization/1** |
| **handle_info/2** | `def` | calls **due/4** → **dispatch/0** → **emit_utilization/0** |
| **terminate/2** | `def` | calls **unsubscribe_gate/1** → **state.gate/0** → **Enum.each/2** → **state.jobs/0** → **cancel_timer/2** → **job.timer_ref/0** → **state.running/0** → **stop_task/2**; references **Enum** |


## Communication and data flow

Public control uses local synchronous `GenServer.call/3`. Schedule and deadline
timers send local messages. Callback tasks are monitored rather than linked to
the scheduler. The system timer calls only Erlang's `:timer`; recurrence parsing and
arithmetic call `Periodical.Recurrence`, which implements RFC 5545 `RRULE`
over `ical`; telemetry is emitted through `:telemetry`. Periodical itself has no database, filesystem,
HTTP, broker, or cache effects.

## Configuration and operational behavior

`Periodical.Config` is the only production application-configuration reader.
It never reads OS variables or environment files. A host runtime boundary may
place normalized values into its namespace. The validated struct lives in
scheduler state, so setting changes require application restart.

Change expression semantics in `Periodical.Recurrence`, passive occurrence calculations
in `Periodical.Schedule`, validation in **Periodical.Job**, lifecycle policy in
**Periodical.Scheduler**, and event schemas in `Periodical.Telemetry`. Clock and
timer implementations are explicit deterministic substitution boundaries, not
implicit global state.

## Failure, concurrency, and observability

Schedule, pending, and running limits are per node. Replicas intentionally
duplicate schedules, so callbacks that publish externally must use an
application-owned idempotency/deduplication contract. Callback exits and
timeouts do not crash the scheduler and are never retried locally. Scheduler
failure loses state and its supervisor restarts an empty scheduler.

Telemetry uses finite result, reason, operation, and kind values. Callback
arguments, names, local identifiers, return values, and exception text are not
metric tags. The library declares events but starts no reporter or listener.

## Development guide

Begin registration changes in `Periodical.every/5` or `once/5`, follow the
schedule calculation, then inspect the matching scheduler call/message path.
Update policy tests and this document with timing, overlap, misfire, drain, or
process-ownership changes. Run `mix setup`, `mix precommit`, warning-strict
production compilation, ExDoc, architecture audit, and package inspection. No
external integration system is required or automatically started.
