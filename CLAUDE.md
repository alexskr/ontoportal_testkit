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

This gem has no test suite of its own; the integration smoke tasks above are how behavior gets validated, driven end-to-end through a cloned or copied consumer repo.

## Architecture

### Task loading boundary (important)

`lib/ontoportal/testkit/tasks.rb` defines `COMPONENT_TASK_FILES` — an explicit allowlist of `.rake` files loaded when a consumer does `require "ontoportal/testkit/tasks"`. Only `base_image.rake`, `config.rake`, `docker_based_test.rake`, `init.rake` cross that boundary. `integration_smoke.rake` is intentionally excluded and only loads in this repo via its own `rakelib/`. When adding a new task file, decide which side it belongs on and update `COMPONENT_TASK_FILES` if it's component-facing.

Rake does not auto-discover task files inside a gem's `rakelib/`, so `tasks.rb` explicitly `add_import`s each allowlisted file and re-invokes `load_imports` (guarded via `send` for Capistrano compatibility — see 3725d29).

### Compose file layering

`rakelib/docker_based_test.rake` composes each invocation from four directories under `docker/compose/`:

- `base.yml` — always included; defines `test-container`, `redis-ut`, `solr-ut`, and all backend services gated by compose profiles (`fs`, `ag`, `vo`, `gd`, `container`).
- `backends/<key>.yml` — only added in `:container` mode; wires backend hostname/port env into `test-container`.
- `services/<name>.yml` — one per entry in `dependency_services` (e.g. `mgrep.yml`). Independent of backend choice.
- `runtime/no-ports.yml` + `runtime/no-ports-<service>.yml` — only in `:container` mode; strips host port bindings so parallel backend runs don't collide.

Profile selection mirrors this: `selected_profiles(key, container:)` returns `[backend, "container"?, *dependency_services]`.

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
- Shell out via the `shell!` helper in `docker_based_test.rake`; it echoes the command and aborts on failure. Use `Shellwords.escape` for any path interpolated into a compose command.
- Env-var overrides are prefixed `OPTK_` (testkit) or `GOO_` (backend wiring consumed by the component's test code).
