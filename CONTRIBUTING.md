# Contributing to Periodical

Thanks for considering a contribution. This document covers what you need
to know before opening an issue or a pull request.

## Getting started

```sh
git clone https://github.com/joetjen/periodical.git
cd periodical
mix deps.get
mix test
```

That should complete with no failures on a clean checkout. If it doesn't,
please open an issue first; that is a bug in its own right. `.tool-versions`
pins the Erlang and Elixir versions the project is developed against, if you
use `asdf` or `mise`. CI also runs on OTP 26 and 27.

The multi-instance tests (`test/periodical/cluster_test.exs`) start real
`:peer` nodes on `127.0.0.1`. They start `epmd` themselves and need nothing
else: no database, broker, or container.

Periodical has two runtime dependencies, both from Hex: `ephemeris` (recurrence
parsing and occurrence arithmetic) and `telemetry`. Keep it that way. Anything
that needs a store or a client library belongs in a separate package, the way
`periodical_redis` and `periodical_ecto` implement `Periodical.Coordinator`.

## Project layout

- `lib/periodical.ex`: the public API (`every/5`, `once/5`, `cancel/1`,
  `pause/1`, `resume/1`, `stats/0`, `drain/1`).
- `lib/periodical/scheduler.ex`: the scheduler process, which owns schedule
  state, timers, overlap, misfire, and drain policy.
- `lib/periodical/coordinator.ex`, `lib/periodical/coordination.ex`: the
  optional cluster-wide coordination behaviour, and the claim, strategy, and
  lease-renewal logic that runs inside each callback task.
- `lib/periodical/recurrence.ex`, `lib/periodical/schedule.ex`: recurrence rules
  (a boundary over Ephemeris) and passive occurrence calculations.
- `lib/periodical/config.ex`: the only reader of application configuration,
  with validation.
- `test/periodical/`: unit, property, lifecycle, package, and multi-instance
  tests.
- `test/support/`: the shared lease store, coordinators, and skewed clock used
  by the coordination tests. It is compiled to disk in `:test` so peer nodes
  can load it, and is never part of the package.
- `guides/`: usage, examples, and architecture, published with the module docs.

`guides/architecture.md` has the full code map and the runtime design.

## Making a change

1. **Tests with the change.** A change in behavior comes with tests for the
   new behavior in the same commit. Where the inputs form a large space (rule
   handling, lease and delay arithmetic, configuration normalization), prefer a
   property test with `stream_data` over more hand-picked examples.
2. **Timing tests use the replaceable clock and timer.** `Periodical.Clock` and
   `Periodical.Timer` exist so tests control time instead of sleeping on the
   wall clock. Only the multi-instance tests run in real time, and they assert
   ranges rather than exact counts.
3. **Keep the scheduler non-blocking.** The scheduler is one process for the
   whole node. Anything that can wait (a callback, a coordinator call, a load
   delay) runs in the supervised callback task, not in the scheduler.
4. **Documentation is part of the change.** Every public module needs a
   `@moduledoc` and every public function a `@doc`. Update them, the README,
   the guides, and `CHANGELOG.md` (under `[Unreleased]`, in
   [Keep a Changelog](https://keepachangelog.com/) form) when behavior changes.
5. **Run the full verification pass before opening a PR:**

   ```sh
   mix precommit
   mix docs
   ```

   `mix precommit` (an alias in `mix.exs`) runs a forced, warning-strict
   compile, `format --check-formatted`, `credo --strict`, `dialyzer`, and the
   test suite under `MIX_ENV=test`. The first Dialyzer run builds a PLT, which
   takes a minute or two. A new Dialyzer or Credo finding is not automatically
   wrong, but it needs a specific justification next to the code, never a
   blanket suppression.

   `mix docs` is not part of the alias, but run it whenever you touch a
   moduledoc or a guide: ExDoc warns about broken references without failing.
   `.github/workflows/docs.yml` publishes the same output to
   [GitHub Pages](https://joetjen.github.io/periodical/) on every push to
   `main`.

## Branches and commits

The project uses [git flow](https://nvie.com/posts/a-successful-git-branching-model/):
branch `feature/*` from `develop` and open the pull request against `develop`.
`main` only receives releases. Commit messages follow
[Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`,
`docs:`, …), and versions follow [Semantic Versioning](https://semver.org/).

## Reporting bugs

Please include the Periodical and Elixir/OTP versions, the registration call
(rule or time, callback, and options), the relevant configuration (including the
coordinator, if one is configured), what you expected, and what happened,
including the full `%Periodical.Error{}` or the telemetry events where they help.
A minimal reproduction is the fastest way to a fix.

## License

By contributing, you agree that your contributions will be licensed
under the project's [Apache License 2.0](LICENSE).
