# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this gem is

`ontoportal_testkit` packages shared Docker-driven test tooling for OntoPortal component repos (`goo`, `ontologies_linked_data`, `ncbo_annotator`, `ncbo_recommender`, `ncbo_cron`, `ontologies_api`). Consumer components gain `test:docker:*` and `test:testkit:*` rake tasks by adding this gem as a dev dependency and loading it from their `Rakefile` or `rakelib/`. There is no application code — the deliverable is rake tasks, compose files, and init templates.

## Common commands

```bash
bundle install
bundle exec rake -T                      # list all tasks
bundle exec standardrb                   # lint (from standard/rake)
bundle exec standardrb --fix             # autofix
bundle exec rake test:testkit:init       # scaffold files in a consumer repo (run with [force] to skip prompts)
bundle exec rake test:testkit:config     # dump resolved ComponentConfig
bundle exec rake test:docker:up:all      # start all backends + dependency services
bundle exec rake "test:docker:down[all]"
bundle exec rake test:docker:fs          # host-Ruby tests against 4store backend
bundle exec rake test:docker:fs:container        # tests inside linux container
bundle exec rake test:docker:fs:container:dev    # faster dev loop (mounted source, cached bundle)
bundle exec rake test:docker:all:container       # all backends in parallel (forks children)
bundle exec rake "test:docker:shell[fs]"         # interactive shell in the test container
```

Docker base-image build (arch + tag args are positional):

```bash
bundle exec rake "test:testkit:docker:build_base[3.2,bullseye,ontoportal/testkit-base:ruby3.2-bullseye,true]"
```

Maintainer integration smoke (this repo only — not shipped to consumers):

```bash
bundle exec rake test:testkit:integration:goo
bundle exec rake test:testkit:integration:configured   # iterates .ontoportal-testkit.integration.yml
OPTK_COMPONENT_PATH=../goo bundle exec rake test:testkit:integration:component
```

This gem has no unit test suite. Behavior is validated two ways: the integration smoke tasks above, driven end-to-end through a cloned or copied consumer repo, and `test:testkit:integration:compose_ports` — a pure `docker compose config` contract check over the packaged compose files that needs no consumer, no containers, and no scaffold files. The contract check is the only guard on commit 895b01a (the `ports: !override []` fix) and on `base.yml` ↔ `BACKENDS` port drift; it lives in `ComposeContract` and calls `DockerTasks#published_ports_for`, the same derivation the port preflight uses, so the two cannot drift apart.

## Architecture

### Task loading boundary (important)

`lib/ontoportal/testkit/tasks.rb` defines `COMPONENT_TASK_FILES` — an explicit allowlist of `.rake` files loaded when a consumer does `require "ontoportal/testkit/tasks"`. Only `base_image.rake`, `config.rake`, `docker_based_test.rake`, `init.rake` cross that boundary. `integration_smoke.rake` is intentionally excluded and only loads in this repo via its own `rakelib/`. When adding a new task file, decide which side it belongs on and update `COMPONENT_TASK_FILES` if it's component-facing.

Prefer adding maintainer-only tasks to the existing `integration_smoke.rake` over creating a new `.rake` file — that keeps them off the allowlist by construction with no new decision to make (this is why `compose_ports` lives there). Note the corollary: `run_testkit_task_or_abort!` in `integration_tasks.rb` drives tasks inside a consumer via `require "ontoportal/testkit/tasks"`, so it can only invoke *allowlisted* tasks. A maintainer-only task has to run in this repo's own rake process.

Rake does not auto-discover task files inside a gem's `rakelib/`, so `tasks.rb` explicitly `add_import`s each allowlisted file and re-invokes `load_imports` (guarded via `send` for Capistrano compatibility — see 3725d29).

### Compose file layering

`rakelib/docker_based_test.rake` composes each invocation from four directories under `docker/compose/`:

- `base.yml` — always included; defines `test-container`, `redis-ut`, `solr-ut`, and all backend services gated by compose profiles (`fs`, `ag`, `vo`, `gd`, `container`).
- `backends/<key>.yml` — only added in `:container` mode; wires backend hostname/port env into `test-container`.
- `services/<name>.yml` — one per entry in `dependency_services` (e.g. `mgrep.yml`). Independent of backend choice.
- `runtime/no-ports.yml` + `runtime/no-ports-<service>.yml` — only in `:container` mode; strips host port bindings so parallel backend runs don't collide.

Compose **concatenates** sequence-valued keys across `-f` files rather than replacing them — this affects `ports`, `expose`, `external_links`, `dns`, `dns_search`, and `tmpfs`. An override that wants to *remove* one of those must tag it (`ports: !override []`, or `!reset` to drop the key entirely); a bare `ports: []` merges into the base list and silently does nothing. That was the bug in `runtime/no-ports*.yml`: the files existed and were passed to compose, but host ports stayed bound. `!override` needs Compose v2.24.0+ (see README requirements). Verify any change here with `docker compose -f ... config` and confirm no `published:` entries survive — nothing in CI binds these ports, so a regression only surfaces on a dev machine running two components at once.

Profile selection mirrors this: `selected_profiles(key, container:)` returns `[backend, "container"?, *dependency_services]`.

### Host port safety

`compose_up` is the single funnel for every task that starts containers, so all three host-port
guards live there rather than at call sites. That is also what makes them *correct* for
`with_container_stack`, which passes a narrowed profile list (`profiles - ["container"]`) — deriving
the port set from `compose_up`'s own `profiles:` argument is automatically right, where deriving it
at the call site would use the wrong list.

- `configured_port_bindings` gets the expected ports from `docker compose config --format json` over
  the same file set and profiles. So `base.yml` stays the single source of truth, and `:container`
  mode is inert by construction — `runtime/no-ports*.yml` strip every `ports` entry, so the set is
  empty and all three guards return early.
- **Preflight** (`ensure_host_ports_available!`): a `TCPServer` bind probe on both `0.0.0.0` and
  `[::]`, counting **only** `EADDRINUSE` as a conflict — IPv6 being unavailable or a sandboxed bind
  means "unknown, allow through", because a false positive blocks a legitimate run while a false
  negative just defers to compose, which now cleans up after itself. `docker ps --filter publish=`
  attributes each conflict, and **suppresses it when the holder's `com.docker.compose.project`
  equals our `compose_scope`** — without that, `up[fs]` → `test:docker:fs` would abort on its own
  stack.
- **Post-`up` verification** (`missing_published_ports`): compares `docker compose ps`'s
  `Publishers` against the expected set. Checks "missing", never "extra", so adding a service can't
  false-positive. Fails open at every step — a bug here would silently `--force-recreate` on every
  run, and gd/ag pay 30-60s each time.

All of this exists because of [moby/moby#51758](https://github.com/moby/moby/issues/51758) (open as
of Engine 29.x): a container whose first start fails on a port conflict has
`NetworkSettings.Networks` wiped by the daemon's rollback, and every later start attaches no
networking at all. `HostConfig.PortBindings` survives but is never applied. Since the backend
healthchecks in `base.yml` are container-local, `up --wait` reports the stack healthy while nothing
is reachable from the host. Measured signature on a leftover container:
`state=created PortBindings={"8983/tcp":[…]} Networks={}`.

`cleanup_failed_compose_up!` is the load-bearing fix: a failed `up` tears down what it partially
created, so nothing survives to be resurrected. It honors `OPTK_KEEP_CONTAINERS=1` (a failed run is
the highest-value moment to inspect state) and warns with the recovery command when it does. The
teardown is deliberately non-strict — a cleanup failure must not mask the original `up` failure.
Note `compose_up_attempt!` leaves the started flag unset on the failure path on purpose: `abort_with`
raises `SystemExit`, `with_backend_compose`'s `ensure` runs, sees `false`, and skips a redundant
second `down`.

**Never pass `--remove-orphans` by default.** `with_container_stack` calls `compose_up` without the
`container` profile, which makes `test-container` an orphan candidate; compose excludes
`com.docker.compose.oneoff=True` containers today, but that is an undocumented implementation
detail, not a contract. `--force-recreate` is likewise self-heal-only (capped at one retry) plus an
opt-in env var — defaulting it would destroy the container reuse that makes `up[fs]` →
`test:docker:fs` fast.

### Compose project scoping

`compose_scope_name(key:, container:)` returns something like `goo-fs-container`, used as `docker compose -p <scope>`. This is what allows `test:docker:all:container` to fork one child process per backend and have them run in parallel without container/network name collisions. Any new task that brings up containers must derive its scope the same way, or concurrent runs will clobber each other.

`compose_base` also exports `OPTK_TESTKIT_ROOT` so compose files can mount gem-packaged fixtures (e.g. `docker/fixtures/backends/virtuoso_initdb_d`) using an absolute path resolved at the gem's install location, not the consumer's CWD.

### Dev-mode flags

`container_dev_mode?` (via `OPTK_TEST_DOCKER_CONTAINER_DEV_MODE=1`, set by `*:container:dev` wrappers) is a meta-flag that flips three others to their dev defaults:

- `OPTK_TEST_DOCKER_CONTAINER_BUILD=0` (skip `--build`)
- `OPTK_TEST_DOCKER_CONTAINER_MOUNT_WORKDIR=1` (bind-mount `$PWD:/app`)
- `OPTK_TEST_DOCKER_CONTAINER_BUNDLE_VOLUME=1` (named volume at `/usr/local/bundle`)

Each of these can be set individually when you want partial dev behavior.

### Config resolution

`Ontoportal::Testkit::ComponentConfig` reads `.ontoportal-testkit.yml` from the consumer's CWD; `IntegrationConfig` reads `.ontoportal-testkit.integration.yml` from *this gem's root* (maintainer-only). Both use `YAML.safe_load` with no permitted classes — keep configs to plain scalar/hash/array YAML.

### Init scaffolding

`test:testkit:init` renders four files into a consumer repo from `templates/init/`: the component config, a thin `Dockerfile` that `FROM`s `ontoportal/testkit-base`, the `rakelib/ontoportal_testkit.rake` loader, and a GitHub Actions workflow. `required_scaffold_paths` (config + Dockerfile) are preflight-checked before any `test:docker:*` task runs; missing files abort with a pointer to `init`.

Running `init` without `[force]` prints a diff against existing files and prompts interactively before overwriting. Integration smoke runs pass `[force]` to avoid the prompt.

### Backend matrix

`BACKENDS` (in `docker_based_test.rake`) is the single source of truth for the four backends and the host-side env vars (`GOO_BACKEND_NAME`, `GOO_PORT`, `GOO_PATH_*`) that `run_host_tests` exports before invoking `Rake::Task["test"]`. `backend_label` maps keys to display names. Changing a backend means touching this hash, the matching `docker/compose/backends/<key>.yml`, and the service definition in `base.yml`.

## Conventions

- Ruby 3.1+ (`required_ruby_version`).
- Lint with `standardrb` — the `Rakefile` loads `standard/rake`, so `rake standard` also works.
- Shell out via the helpers on `DockerTasks`: `shell?` echoes and returns a boolean, `shell!` is `shell? || abort_with`, and `capture` returns `[combined_output, success]` without echoing (for the checks that run on every `up`). There is deliberately no `capture!` — every caller wants its own failure policy. Use `Shellwords.escape` for any path interpolated into a compose command.
- **Any** raw compose invocation must go through `compose_base`, which exports `OPTK_TESTKIT_ROOT`. `base.yml` declares `${OPTK_TESTKIT_ROOT:?…}`, so a bare `docker compose` call hard-fails with `error while interpolating services.virtuoso-ut.volumes.[]: required variable OPTK_TESTKIT_ROOT is missing a value`.
- `docker compose ps --format json` emits NDJSON on v2.21+ and a JSON array before that; parse it with `parse_compose_json_stream`, which accepts either and never raises.
- Env-var overrides are prefixed `OPTK_` (testkit) or `GOO_` (backend wiring consumed by the component's test code).
