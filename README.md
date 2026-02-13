# OntoPortal Testkit

Shared development gem for Docker-driven backend dependencies across OntoPortal Ruby projects.

## Scope

This project is intended to reduce copy/paste across related repos by packaging common development tooling in one place:

- Reusable `rake test:docker:*` task logic
- Shared backend profile conventions (`fs`, `ag`, `vo`, `gd`)
- Per-project overrides via `.ontoportal-test.yml`

## Planned Usage

In consumer projects (`goo`, `ontologies_linked_data`, `ncbo_annotator`, `ncbo_recommender`):

1. Add this gem as a development dependency in `Gemfile`.
2. Add a small `.ontoportal-test.yml` manifest (for project-specific services/config).
3. Require the task loader from the project's `Rakefile`:

```ruby
require "ontoportal/testkit/tasks"
```

Requiring `ontoportal/testkit/tasks` loads all `ontoportal_testkit` rake tasks from this gem (`rakelib/*.rake`) into the consumer project.

This is intentionally a practical first step. It does not yet attempt to fully centralize all CI behavior for all projects.

## Optional Services

Optional dependency services (for example `mgrep`) are configured independently from triplestore backend selection.

- Backend remains one of: `fs`, `ag`, `vo`, `gd`
- Optional services are listed in `.ontoportal-test.yml` under `optional_services`
- Service override files are loaded from `dev/compose/linux/<service>.yml`

## Base Image

Use `ontoportal_testkit` as the shared Docker dependency base and keep each project Dockerfile thin.

Build the shared base image:

```bash
bundle exec rake test:testkit:docker:build_base
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

Validation workflow:

- File: `.github/workflows/validate-base-image.yml`
- Runs on pull requests and only builds the base image (no push)

Required repository secrets:

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

Consumer project `Dockerfile` pattern:

```dockerfile
ARG TESTKIT_BASE_IMAGE=ontoportal/testkit-base:ruby3.2-bullseye
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
```
