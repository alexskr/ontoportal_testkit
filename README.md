# OntoPortal Testkit

Shared development gem for Docker-driven backend dependencies across OntoPortal components.

## Scope

This toolkit is intended to reduce copy/paste across related repos by packaging common development tooling in one place:

- Reusable `rake test:docker:*` task logic
- Shared backend profile conventions (`fs`, `ag`, `vo`, `gd`)
- Per-component overrides via `.ontoportal-testkit.yml`

## Planned Usage

In consumer components (`goo`, `ontologies_linked_data`, `ncbo_annotator`, `ncbo_recommender`, `ncbo_cron`, `ontologies_api`):

1. Add this gem as a development dependency in `Gemfile`.
2. Initialize scaffold files in the component root:

```bash
bundle exec rake test:testkit:init
```

This creates `.ontoportal-testkit.yml`, `Dockerfile`, and `rakelib/ontoportal_testkit.rake` (task loader) if missing.
If you do not want the `rakelib` loader file, you can instead add this in component `Rakefile`:

```ruby
require "ontoportal/testkit/tasks"
```

Requiring `ontoportal/testkit/tasks` loads all `ontoportal_testkit` rake tasks from this gem (`rakelib/*.rake`) into the consumer component.
The docker tasks use the compose files packaged inside this gem (`docker/compose/base.yml` and `docker/compose/**/*.yml`), not compose files from the consumer repo.
Compose commands use component name from `.ontoportal-testkit.yml` (`component_name`) via `docker compose -p`, so container/network names reflect the consumer component.
For backend-scoped runs, compose scope names are suffixed per backend (and `-linux` for Linux container runs) so different backend runs can execute in parallel without collisions.

This is intentionally a practical first step. It does not yet attempt to fully centralize all CI behavior for all components.

## Dependency Services

Component-specific dependency services (for example `mgrep`) are configured independently from triplestore backend selection.

- Backend remains one of: `fs`, `ag`, `vo`, `gd`
- Dependency services are listed in `.ontoportal-testkit.yml` under `dependency_services`
- Service override files are loaded from `docker/compose/services/<service>.yml`

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

```bash
cd ontoportal_testkit
bundle install
bundle exec rake -T
bundle exec rake test:docker:up:all
bundle exec rake test:docker:all:linux
bundle exec rake "test:docker:down[all]"
```
