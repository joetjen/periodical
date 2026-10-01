# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-01

The first public release. Periodical was extracted from a private workspace,
where it went through unpublished versions up to 1.0.3 (see
[Before the public release](#before-the-public-release)); "breaking" below is
relative to the last of them.

### Changed

- **Periodical is an independent, MIT-licensed library.** Its private
  predecessor depended on five in-house libraries; the runtime dependencies now
  are `:telemetry` and `ephemeris`.
- **Recurrence accepts both RFC 5545 `RRULE` and plain English**, through
  [Ephemeris](https://github.com/joetjen/ephemeris). Expressions such as
  `"Every 30 seconds"` and `"Every monday at 9:30 am"` keep working, and the
  same rules can be written or stored as `FREQ=SECONDLY;INTERVAL=30` and
  `FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=30`.

  Ordinal weekdays (`every last Sunday of the month`), `BYSETPOS`
  (`every last weekday of the month`) and correct month-length and leap-year
  handling are now expressible: `every 31st of the month` skips February rather
  than firing on the 28th. `Periodical.Recurrence.to_rrule/1` and
  `to_sentence/1` render a rule either way.
- **BREAKING**: telemetry events are `[:periodical, …]`, emitted through
  `:telemetry` directly. Trigger execution is a `:telemetry` span carrying the
  trigger kind and schedule identifier, so a host bridging spans to its tracer
  gets one per trigger without Periodical depending on a tracing library.
- **BREAKING**: the health gate is configured rather than assumed. Supply any
  module implementing the `Periodical.Gate` behaviour:

      config :periodical, gate: MyApp.HealthGate

  Its transition messages are `{:periodical_gate, gate, :open}` and
  `{:periodical_gate, gate, :closed, reason}`; `config :periodical,
  gate_message: :other_tag` adapts a gate that announces itself under another
  tag.
- **BREAKING**: context propagation from registration to execution is pluggable
  through the `Periodical.Telemetry.Context` behaviour, defaulting to
  `Logger.metadata/0`.
- Overlap skip and misfire skip are the safe defaults; fire-once coalescing and
  concurrent overlap are explicit policies.
- Periodical is local and in-memory; persistence, retries or cross-replica
  coordination need an explicit durable handoff.
- `Periodical.Error` is a plain exception with the same fields and per-code
  constructors.

### Added

- Bounded recurring and one-time MFA scheduling with typed trigger context,
  pause, resume and cancel, optional health-gate admission, count-only
  statistics and telemetry.
- Validated operational configuration, pure schedule calculation and execution
  deadlines.
- `Periodical.drain/1`: bounded shutdown that closes admission and waits for
  active callbacks, with a structured timeout result.
- `ARCHITECTURE.md`, included in the generated documentation after the README.
- Dependency-vulnerability, licence, secret-detection, SBOM and provenance
  checks in CI; development-only and not part of the published package.

### Removed

- The anonymous-function, integer-interval, `at`, immediate, startup-latch,
  startup-failure and implicit-retry contracts of the private versions.

### Fixed

- `mix hex.publish` runs in the `docs` environment, where `ex_doc` is
  available, instead of failing because the `docs` task is missing in `dev`.
- Dialyzer passes: the gate checks no longer test `is_atom/1` on a value typed
  `module() | nil`.
- The README links the usage and examples guides at their `guides/` paths.

## Before the public release

Unpublished versions from the private workspace, kept for their history. None
of them was released to Hex; their numbers predate the public 0.1.0.

### 1.0.3 (private)

#### Fixed

- Replaced runtime `Mix.env/0` startup-gate checks with compile-time environment capture (`Mix.env/0` when available, otherwise `MIX_ENV`), so runtime uses the compiled value and works correctly in OTP releases where Mix is unavailable.

### 1.0.2 (private) - 2026-06-02

#### Changed

- Updated the `asco_error` runtime dependency constraint from `~> 1.1.3` to `~> 1.1`.

#### Added

- Added `immediately` scheduling option to run first execution without waiting.
- Added `startup` option for startup-essential tasks (implies immediate first run).
- Added `on_startup_failure` callback support for startup-essential failures before first success.
- Added startup gate integration with `ASCO.HealthCheck`:
  - Queue non-essential tasks until startup completes.
  - Execute startup-essential tasks immediately during startup.
  - Mark startup complete after each startup-essential task succeeds once.

#### Changed

- Extended scheduler internals to support immediate first-run delay control while preserving recurring cadence.
- Extended telemetry metadata with startup-related fields (`startup_task`, `startup_blocked`) for next-run and execution context.
- Startup gating now treats temporary `ASCO.HealthCheck.startup_complete?/0` read failures as `startup incomplete` and retries startup hook registration instead of releasing non-essential tasks early.

### 1.0.0 (private) - 2026-02-25

#### Added

- Added exploratory SVG logo concepts under `branding/` for visual identity work.

#### Changed

- **BREAKING**: Migrated telemetry module to ASCO.Telemetry DSL-based system.
  - `Periodical.Telemetry.events/0` now auto-generated from `defduration` and `defcounter` macros
  - `Periodical.Telemetry.metrics/0` exported for automatic Prometheus integration
  - Use `use ASCO.Telemetry` instead of manual `events/0` declarations
- Switched scheduler telemetry emissions to DSL-generated emitters.

### 0.3.0 (private) - 2026-02-18

#### Changed

- **BREAKING**: Refactored `Periodical.every/at` signatures to explicit positional forms plus keyword options (`args`, `timer`, `name`), removing ambiguous overloads.

### 0.2.3 (private) - 2026-02-17

#### Changed

- **BREAKING**: Normalized telemetry events to consistent 4-atom pattern:
  - `[:periodical, :scheduler, :job_execute, :duration]` → `[:periodical, :scheduler, :job, :duration]`
  - `[:periodical, :scheduler, :job_execute, :count]` → `[:periodical, :scheduler, :job, :success]`
  - `[:periodical, :scheduler, :job_failure, :count]` → `[:periodical, :scheduler, :job, :failure]`
  - `[:periodical, :scheduler, :next_run, :value]` remains unchanged
- Changed telemetry duration tracking from span events to direct measurement for consistency

### 0.2.1 (private) - 2026-02-17

#### Changed

- Updated `asco_utils` dependency from 0.1.0 to 0.1.1
- Updated `asco_error` dependency from 0.1.0 to 0.2.0
- Added release instructions to AGENTS.md for maintaining the changelog

### 0.2.0 (private) - 2026-01-15

#### Changed

- Version bump to 0.2.0 for telemetry features release

### 0.1.0 (private) - 2026-01-13

#### Added

##### Core Scheduling System

- `Periodical.every/2-4` - Schedule interval-based recurring tasks
- `Periodical.at/2-4` - Schedule time-based recurring tasks
- `Periodical.Telemetry` module with Prometheus-compatible metrics:
  - `[:periodical, :scheduler, :job_execute, :duration]` - Distribution metric for job execution time
  - `[:periodical, :scheduler, :job_execute, :count]` - Counter for number of job executions
  - `[:periodical, :scheduler, :job_failure, :count]` - Counter for job failures
  - `[:periodical, :scheduler, :next_run, :value]` - Last value gauge for seconds until next run
- GenServer-based task scheduler (`Periodical.Scheduler`) for managing timers and rescheduling
- GenServer-based task executor (`Periodical.TaskManager`) for isolated task execution
- Supervision tree with OTP application for fault tolerance
- Support for both anonymous functions and MFA (Module-Function-Arguments) pattern

##### Interval Scheduling

- Millisecond-based interval scheduling (e.g., `5000` for 5 seconds)
- Human-readable duration strings:
  - Seconds: "5s", "30 seconds", "1 second"
  - Minutes: "5m", "10 minutes", "1 minute"
  - Hours: "1h", "2 hours", "1 hour"
- Automatic task rescheduling for recurring intervals
- Flexible interval parsing with singular/plural support

##### Time-Based Scheduling

- Time string specifications (e.g., "5:30pm", "14:30", "9:00am")
- Special time names:
  - "midnight" - 00:00
  - "noon" - 12:00
- Daily recurring execution at specified times
- Automatic next-day scheduling for time-based tasks

##### Task Execution

- Isolated process execution for fault tolerance
- Task argument passing support
- Automatic error handling and stacktrace logging
- Task completion callbacks
- Recurring task automatic rescheduling

##### Error Handling

- `Periodical.Error` exception module with structured error types
- Validation errors for invalid interval strings
- Validation errors for invalid time specifications
- Validation errors for invalid periodic strings
- Comprehensive error messages with helpful context

##### Testing

- 62 comprehensive tests covering all scheduling patterns
- Test coverage: 77.78%
- Tests for interval parsing and validation
- Tests for time-based scheduling
- Tests for error conditions
- Tests for task execution and isolation

##### Documentation

- Comprehensive README with overview and architecture (204 lines)
- QUICKSTART.md - Get started guide with common patterns (498 lines)
- USAGE_GUIDE.md - Complete API reference and best practices (1033 lines)
- EXAMPLES.md - Real-world examples including:
  - Background job processing
  - Report generation (daily, weekly, monthly)
  - Data synchronization patterns
  - Health monitoring systems
  - Cache management strategies
  - Cleanup task patterns
  - Notification systems
  - Cron-like scheduling
  - Advanced scheduling patterns (1376 lines)
- AGENTS.md - Development workflow and conventions

##### Command-Line Interface

- `bin/start` - Start interactive IEx session
- `bin/stop` - Stop running application
- `bin/list` - List scheduled tasks
- `bin/log` - View application logs

##### CI/CD

- GitLab CI configuration for automated testing
- Documentation generation and deployment to GitLab Pages
- Code quality checks with Credo
- Type checking with Dialyzer
- Test coverage reporting

##### Dependencies

- No external runtime dependencies beyond Elixir stdlib
- Development dependencies for testing and documentation
- Integration with ASCO.Utils for time parsing utilities
