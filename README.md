# OntoPortal Testkit

Shared development gem for Docker-driven backend dependencies across OntoPortal components.

## Scope

This toolkit is intended to reduce copy/paste across related repos by packaging common development tooling in one place:

- Reusable `rake test:docker:*` task logic
- Shared backend profile conventions (`fs`, `ag`, `vo`, `gd`)
- Per-component overrides via `.ontoportal-testkit.yml`

## Requirements

- Docker Compose **v2.24.0 or newer**. The `runtime/no-ports*.yml` overrides use the
  `!override` merge tag, which older versions do not understand — `test:docker:*:container`
  runs will fail with a YAML parse error on those files.

## Planned Usage

In consumer components (`goo`, `ontologies_linked_data`, `ncbo_annotator`, `ncbo_recommender`, `ncbo_cron`, `ontologies_api`):

1. Add this gem as a development dependency in `Gemfile`.
2. Initialize scaffold files in the component root:

```bash
bundle exec rake test:testkit:init
```

This creates `.ontoportal-testkit.yml`, `Dockerfile`, `rakelib/ontoportal_testkit.rake` (task loader), and `.github/workflows/testkit-unit-tests.yml` if missing.
If you do not want the `rakelib` loader file, you can instead add this in component `Rakefile`:

```ruby
require "ontoportal/testkit/tasks"
```

Requiring `ontoportal/testkit/tasks` loads the component-facing `ontoportal_testkit` rake tasks from this gem (init/config/base-image/docker tasks) into the consumer component.
The docker tasks use the compose files packaged inside this gem (`docker/compose/base.yml` and `docker/compose/**/*.yml`), not compose files from the consumer repo.
Compose commands use component name from `.ontoportal-testkit.yml` (`component_name`) via `docker compose -p`, so container/network names reflect the consumer component.
For backend-scoped runs, compose scope names are suffixed per backend (and `-container` for container runs) so different backend runs can execute in parallel without collisions.

This is intentionally a practical first step. It does not yet attempt to fully centralize all CI behavior for all components.

## Dependency Services

Component-specific dependency services (for example `mgrep`) are configured independently from triplestore backend selection.

- Backend remains one of: `fs`, `ag`, `vo`, `gd`
- Dependency services are listed in `.ontoportal-testkit.yml` under `dependency_services`
- Service override files are loaded from `docker/compose/services/<service>.yml`
- `test:testkit:init` scaffolds `dependency_services: [mgrep]` by default (set `DEPENDENCY_SERVICES=` to scaffold none)

## Base Image

Use `ontoportal_testkit` as the shared Docker dependency base and keep each component Dockerfile thin.

Build the shared base image:

```bash
bundle exec rake test:testkit:docker:build_base
```

This builds both `linux/amd64` and `linux/arm64/v8` images as a local OCI archive (`tmp/*.oci.tar`).
To push a multi-arch manifest to Docker Hub, pass `push=true`:

```bash
bundle exec rake "test:testkit:docker:build_base[3.2,bullseye,ontoportal/testkit-base:ruby3.2-bullseye,true]"
```

You can override version/tag:

```bash
bundle exec rake "test:testkit:docker:build_base[3.2,bullseye,ontoportal/testkit-base:ruby3.2-bullseye]"
```

GitHub Actions workflow:

- File: `.github/workflows/publish-base-image.yml`
- Publishes on GitHub Release (`published`) or manual dispatch
- Supports manual dispatch with `ruby_version`, `distro`, `push_image`
- Docker Hub repo: `ontoportal/testkit-base`
- Release publishes immutable versioned tags like `v0.1.0-ruby3.2-bullseye`
- Also updates moving aliases like `ruby3.2-bullseye` (and `latest` for default line)

Validation workflow:

- File: `.github/workflows/validate-base-image.yml`
- Runs on pull requests and only builds the base image (no push)

Required repository secrets:

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

Consumer component `Dockerfile` pattern:

```dockerfile
ARG RUBY_VERSION=3.2
ARG DISTRO=bullseye
ARG TESTKIT_BASE_IMAGE=ontoportal/testkit-base:ruby${RUBY_VERSION}-${DISTRO}
FROM ${TESTKIT_BASE_IMAGE}

WORKDIR /app
COPY Gemfile* *.gemspec ./
RUN bundle install --jobs 4 --retry 3
COPY . ./
CMD ["bundle", "exec", "rake"]
```

## Local Development

Initialize scaffold files before running docker tasks in this repo:

```bash
bundle exec rake test:testkit:init
```

If `Dockerfile` or `.ontoportal-testkit.yml` is missing, `test:docker:*` tasks will stop and remind you to run init.

```bash
cd ontoportal_testkit
bundle install
bundle exec rake -T
bundle exec rake test:docker:up:all
bundle exec rake test:docker:all:container
bundle exec rake "test:docker:down[all]"
```

### Faster Linux Docker test loop

By default, `test:docker:*:container` runs with `docker compose run --build`, which ensures a fresh image but adds rebuild overhead.
You can enable a faster dev loop with mounted source and cached gems using dedicated dev aliases:

```bash
bundle exec rake test:docker:fs:container:dev
bundle exec rake test:docker:all:container:dev
bundle exec rake "test:docker:shell:dev[fs]"
```

Dev aliases enable `OPTK_TEST_DOCKER_CONTAINER_DEV_MODE=1`, which implies:

- `OPTK_TEST_DOCKER_CONTAINER_BUILD=0` (skip `--build`)
- `OPTK_TEST_DOCKER_CONTAINER_MOUNT_WORKDIR=1` (mount current repo at `/app`)
- `OPTK_TEST_DOCKER_CONTAINER_BUNDLE_VOLUME=1` (named volume at `/usr/local/bundle`)

You can also set these flags independently if you only want part of the behavior.

### Host Port Conflicts

Host-Ruby tasks (`test:docker:fs`, `test:docker:up[fs]`, …) publish backend ports on the host so
your local Ruby can reach them. Running two OntoPortal components at once therefore collides:

| Task | Host ports published |
| --- | --- |
| `test:docker:fs` / `up[fs]` | 6379, 8983, 9000 |
| `test:docker:ag` / `up[ag]` | 6379, 8983, 10035 |
| `test:docker:vo` / `up[vo]` | 1111, 6379, 8890, 8983 |
| `test:docker:gd` / `up[gd]` | 6379, 7200, 7300, 8983 |
| `test:docker:up:all` | all eight of the above |
| `mgrep` dependency service | adds 55556 |

`compose_up` checks those ports before starting anything and aborts naming the container and
compose project holding each one, rather than letting compose fail with a bare bind error:

```
Host port conflict(s) detected before `docker compose up` (project ontologies_linked_data-fs):

  8983   held by container goo-fs-solr-ut-1 (compose project: goo-fs, service: solr-ut)

Free those ports, or stop the other stack(s):
  docker compose -p goo-fs down
```

Ports held by your own component's already-running stack are not treated as conflicts, so
`up[fs]` followed by `test:docker:fs` works as expected.

**Container-mode tasks publish nothing on the host and are the recommended way to run two
components at the same time:**

```bash
bundle exec rake test:docker:fs:container
```

Two escape hatches, both off by default:

- `OPTK_TEST_DOCKER_SKIP_PORT_CHECKS=1` — skip the preflight *and* the post-`up` verification.
  `docker compose up` will then fail on bind instead.
- `OPTK_TEST_DOCKER_FORCE_RECREATE=1` — always pass `--force-recreate`. Costly for GraphDB and
  AllegroGraph, which re-initialize from scratch on every recreate.

#### Why the checks exist

[moby/moby#51758](https://github.com/moby/moby/issues/51758) (unfixed as of Docker Engine 29.x): a
container whose first start fails on a port conflict loses its network config, and every later
start attaches no networking at all. Because the backend healthchecks in `base.yml` are
container-local, `docker compose up --wait` then reports the stack **healthy while nothing is
reachable from the host**. Two guards keep that state unreachable:

- A failed `up` tears down the containers it partially created, so none survive to be resurrected.
  Set `OPTK_KEEP_CONTAINERS=1` to keep them for inspection instead — the warning prints the
  `docker compose -p <project> down` needed to clear them.
- After a successful `up`, the ports that were supposed to be published are verified against
  `docker compose ps`. A mismatch triggers exactly one `--force-recreate` retry, then aborts.

## Integration Smoke Test Against a Real Component

These integration smoke tasks are maintainer-focused for the `ontoportal_testkit` repo.
They are not loaded by default in consumer component repos via `require "ontoportal/testkit/tasks"`.

You can run an opt-in smoke test against a local component checkout (for example `goo`) using a temporary copy, so your original checkout is not modified:

```bash
OPTK_COMPONENT_PATH=../goo bundle exec rake test:testkit:integration:component
```

By default, this runs `test:docker:fs:container` in the temporary component copy.
You can override the task list:

```bash
OPTK_COMPONENT_PATH=../goo \
OPTK_INTEGRATION_RAKE_TASKS=test:docker:fs,test:docker:ag \
bundle exec rake test:testkit:integration:component
```

If the component is not yet compatible with your host Ruby test stack, keep it container-only:

```bash
OPTK_INTEGRATION_RAKE_TASKS=test:docker:fs:container \
bundle exec rake test:testkit:integration:goo
```

You can also run smoke tests directly against fresh component clones:

```bash
bundle exec rake test:testkit:integration:goo
bundle exec rake test:testkit:integration:ontologies_linked_data
bundle exec rake test:testkit:integration:ontologies_api
```

Or run all components listed in `.ontoportal-testkit.integration.yml`:

```bash
bundle exec rake test:testkit:integration:configured
```

### Compose Port Contract Check

Verifies the packaged compose files publish exactly the expected host ports for every backend in
both modes — in particular that `:container` mode publishes **nothing**, which is what keeps
parallel runs from colliding:

```bash
bundle exec rake test:testkit:integration:compose_ports
```

Pure `docker compose config`: creates no containers, binds no ports, pulls no images, and needs no
scaffold files, so it is safe to run anywhere docker is installed. It also catches drift between
`base.yml` and the `BACKENDS` matrix in `docker_tasks.rb`.

Config example:

```yaml
repo_org: ncbo
components:
  - goo
  - ontologies_linked_data
  - ontologies_api
```

This file is intended for maintaining `ontoportal_testkit` itself.
It is not required for regular component usage of testkit tasks.

Optional clone controls:

- `OPTK_COMPONENT_REPO_ORG` (default: `ncbo`; for example set to `agroportal`)
- `OPTK_COMPONENT_REPO_URL` (explicit URL override; if set, takes precedence over org/repo naming)
- `OPTK_COMPONENT_REPO_REF` (branch/tag/commit to checkout; takes precedence)
- `OPTK_COMPONENT_REPO_BRANCH` (branch name to checkout when `OPTK_COMPONENT_REPO_REF` is not set)

Example using a branch:

```bash
OPTK_COMPONENT_REPO_ORG=agroportal \
OPTK_COMPONENT_REPO_BRANCH=my-feature-branch \
bundle exec rake test:testkit:integration:goo
```
