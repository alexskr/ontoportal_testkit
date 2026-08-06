require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "socket"
require_relative "component_config"

module Ontoportal
  module Testkit
    # Orchestrates docker compose based backend tests.
    #
    # - Backend names match compose profile names (ag, fs, vo, gd).
    # - Hostnames are NOT set for host Ruby runs; config defaults to localhost.
    # - Compose files are packaged under docker/compose/{base,backends,services,runtime}.
    class DockerTasks
      TESTKIT_ROOT = Ontoportal::Testkit.root
      COMPOSE_ROOT = File.join(TESTKIT_ROOT, "docker/compose")
      BASE_COMPOSE = File.join(COMPOSE_ROOT, "base.yml")
      BACKEND_OVERRIDE_DIR = File.join(COMPOSE_ROOT, "backends")
      SERVICE_OVERRIDE_DIR = File.join(COMPOSE_ROOT, "services")
      RUNTIME_OVERRIDE_DIR = File.join(COMPOSE_ROOT, "runtime")
      CONTAINER_NO_PORTS_OVERRIDE = File.join(RUNTIME_OVERRIDE_DIR, "no-ports.yml")

      BACKENDS = {
        ag: {
          label: "AllegroGraph",
          host_env: {
            "GOO_BACKEND_NAME" => "ag",
            "GOO_PORT" => "10035",
            "GOO_PATH_QUERY" => "/repositories/ontoportal_test",
            "GOO_PATH_DATA" => "/repositories/ontoportal_test/statements",
            "GOO_PATH_UPDATE" => "/repositories/ontoportal_test/statements"
          }
        },
        fs: {
          label: "4store",
          host_env: {
            "GOO_BACKEND_NAME" => "4store",
            "GOO_PORT" => "9000",
            "GOO_PATH_QUERY" => "/sparql/",
            "GOO_PATH_DATA" => "/data/",
            "GOO_PATH_UPDATE" => "/update/"
          }
        },
        vo: {
          label: "Virtuoso",
          host_env: {
            "GOO_BACKEND_NAME" => "virtuoso",
            "GOO_PORT" => "8890",
            "GOO_PATH_QUERY" => "/sparql",
            "GOO_PATH_DATA" => "/sparql",
            "GOO_PATH_UPDATE" => "/sparql"
          }
        },
        gd: {
          label: "GraphDB",
          host_env: {
            "GOO_BACKEND_NAME" => "graphdb",
            "GOO_PORT" => "7200",
            "GOO_PATH_QUERY" => "/repositories/ontoportal_test",
            "GOO_PATH_DATA" => "/repositories/ontoportal_test/statements",
            "GOO_PATH_UPDATE" => "/repositories/ontoportal_test/statements"
          }
        }
      }.freeze

      def initialize
        @started_compose_scopes = {}
      end

      def backend_keys
        BACKENDS.keys
      end

      def backend_label(key)
        BACKENDS.fetch(key).fetch(:label)
      end

      def timeout
        (ENV["OPTK_TEST_DOCKER_TIMEOUT"] || "600").to_i
      end

      def default_backend
        (ENV["OPTK_TEST_DOCKER_BACKEND"] || "fs").to_sym
      end

      def component_config
        @component_config ||= Ontoportal::Testkit::ComponentConfig.new
      end

      def run_host_backend(key)
        ensure_testkit_initialized!
        with_backend_compose(key, container: false) { run_host_tests(key) }
        Rake::Task["test"].reenable
      end

      def run_container_backend(key)
        ensure_testkit_initialized!
        with_backend_compose(key, container: true) { run_container_tests(key) }
      end

      def run_container_backend_dev(key)
        with_container_dev_mode { run_container_backend(key) }
      end

      def run_all_container_parallel(dev: false)
        suffix = dev ? "container:dev" : "container"
        run_backends_in_parallel(task_suffix: suffix)
      end

      def open_shell(backend: nil)
        ensure_testkit_initialized!
        key = (backend || default_backend).to_sym
        cfg!(key)
        files = compose_files_for(key, container: true)
        compose_scope = compose_scope_name(key: key, container: true)
        begin
          run_container_shell(key)
        ensure
          if compose_started?(compose_scope)
            compose_down(files: files, profiles: selected_profiles(key, container: true), compose_scope: compose_scope)
          end
        end
      end

      def open_shell_dev(backend: nil)
        with_container_dev_mode { open_shell(backend: backend) }
      end

      def up(backend: nil)
        key = (backend || default_backend).to_sym
        cfg!(key)
        compose_scope = compose_scope_name(key: key, container: false)
        compose_up(
          files: compose_files_for(key, container: false),
          profiles: selected_profiles(key, container: false),
          compose_scope: compose_scope
        )
      end

      def up_all
        compose_up(
          files: compose_files_for(nil, container: false),
          profiles: all_backend_profiles(container: false),
          compose_scope: compose_scope_name(key: :all, container: false)
        )
      end

      def down(backend: nil)
        if backend.nil?
          configured_backends.each { |key| down_backend(key) }
        elsif backend.to_s == "all"
          compose_down(
            files: compose_files_for(nil, container: false),
            profiles: all_backend_profiles(container: false),
            compose_scope: compose_scope_name(key: :all, container: false)
          )
        else
          key = backend.to_sym
          cfg!(key)
          down_backend(key)
        end
      end

      # Host ports the given stack selection would publish, sorted and deduped.
      #
      # Public so the maintainer-only compose contract check exercises the same
      # derivation the port preflight uses, rather than a parallel
      # reimplementation that could drift from it.
      def published_ports_for(key: nil, container: false, all_backends: false)
        profiles = if all_backends
          all_backend_profiles(container: container)
        else
          selected_profiles(key, container: container)
        end

        # `config` resolves files without touching the daemon, so the project
        # name is irrelevant here — nothing is created under it.
        configured_port_bindings(
          files: compose_files_for(key, container: container),
          profiles: profiles,
          compose_scope: "optk-probe"
        ).map { |binding| binding[:port] }.uniq.sort
      end

      private

      def down_backend(key)
        compose_down(
          files: compose_files_for(key, container: false),
          profiles: selected_profiles(key, container: false),
          compose_scope: compose_scope_name(key: key, container: false)
        )
        compose_down(
          files: compose_files_for(key, container: true),
          profiles: selected_profiles(key, container: true),
          compose_scope: compose_scope_name(key: key, container: true)
        )
      end

      def abort_with(msg)
        warn(msg)
        exit(1)
      end

      def env_true?(name, default: false)
        raw = ENV.fetch(name, default ? "1" : "0").to_s.strip.downcase
        %w[1 true yes on].include?(raw)
      end

      def with_container_dev_mode
        prev = ENV["OPTK_TEST_DOCKER_CONTAINER_DEV_MODE"]
        ENV["OPTK_TEST_DOCKER_CONTAINER_DEV_MODE"] = "1"
        yield
      ensure
        if prev.nil?
          ENV.delete("OPTK_TEST_DOCKER_CONTAINER_DEV_MODE")
        else
          ENV["OPTK_TEST_DOCKER_CONTAINER_DEV_MODE"] = prev
        end
      end

      def shell?(cmd)
        puts "Running: #{cmd}"
        system(cmd) ? true : false
      end

      def shell!(cmd)
        shell?(cmd) || abort_with("Command failed: #{cmd}")
      end

      # Combined stdout+stderr plus success, without echoing — these run on every
      # `up` and shouldn't spam the log. String form is required: compose_base
      # prefixes `OPTK_TESTKIT_ROOT=...` as a shell assignment, and base.yml
      # declares `${OPTK_TESTKIT_ROOT:?...}`.
      #
      # No `capture!` counterpart: every caller here wants its own failure policy
      # (abort with the captured output for `config`, fail open for `ps`).
      def capture(cmd)
        out, status = Open3.capture2e(cmd)
        [out, status.success?]
      end

      def keep_containers?
        env_true?("OPTK_KEEP_CONTAINERS")
      end

      def skip_port_checks?
        env_true?("OPTK_TEST_DOCKER_SKIP_PORT_CHECKS")
      end

      # `docker compose ps --format json` emits NDJSON on v2.21+ and a JSON array
      # before that. Accept either, and never raise — callers fail open.
      def parse_compose_json_stream(raw)
        text = raw.to_s.strip
        return [] if text.empty?
        return Array(JSON.parse(text)) if text.start_with?("[")

        text.each_line.filter_map do |line|
          stripped = line.strip
          stripped.empty? ? nil : JSON.parse(stripped)
        end
      rescue JSON::ParserError
        []
      end

      def cfg!(key)
        cfg = BACKENDS[key]
        abort_with("Unknown backend key: #{key}. Supported: #{BACKENDS.keys.join(", ")}") unless cfg
        cfg
      end

      def compose_files(*files)
        files.flatten.map { |f| "-f #{f}" }.join(" ")
      end

      def profile_flags(profiles)
        Array(profiles).map { |profile| "--profile #{profile}" }.join(" ")
      end

      def compose_scope_name(key: nil, container: false)
        name = component_config.component_name.to_s.strip
        name = File.basename(Dir.pwd) if name.empty?

        scoped = [name, key&.to_s, (container ? "container" : nil)].compact.join("-")
        normalized = scoped.downcase.gsub(/[^a-z0-9_-]/, "-")
        normalized = "op-testkit" if normalized.empty?
        normalized
      end

      def compose_base(files, compose_scope:)
        component_dir = Shellwords.escape(Dir.pwd)
        testkit_root = Shellwords.escape(TESTKIT_ROOT)
        "OPTK_TESTKIT_ROOT=#{testkit_root} docker compose --project-directory #{component_dir} -p #{compose_scope} #{compose_files(files)}"
      end

      def required_scaffold_paths
        [
          Ontoportal::Testkit::ComponentConfig::DEFAULT_PATH,
          "Dockerfile"
        ]
      end

      def ensure_testkit_initialized!
        missing = required_scaffold_paths.reject { |path| File.exist?(path) }
        return if missing.empty?

        abort_with(
          "Missing testkit scaffold file(s): #{missing.join(", ")}. " \
          "Run `bundle exec rake test:testkit:init` in this component first."
        )
      end

      def backend_override_for(key)
        "#{BACKEND_OVERRIDE_DIR}/#{key}.yml"
      end

      def service_override_for(service_name)
        "#{SERVICE_OVERRIDE_DIR}/#{service_name}.yml"
      end

      def dependency_services
        env = ENV["OPTK_TEST_DOCKER_DEPENDENCY_SERVICES"]
        return env.split(",").map(&:strip).reject(&:empty?) if env && !env.strip.empty?

        component_config.dependency_services.map(&:to_s)
      end

      def dependency_override_files
        dependency_services.map do |service_name|
          override = service_override_for(service_name)
          abort_with("Missing dependency service override file: #{override}") unless File.exist?(override)
          override
        end
      end

      def compose_files_for(key = nil, container: false)
        files = [BASE_COMPOSE]
        files << backend_override_for(key) if container && key
        files.concat(dependency_override_files)
        files.concat(runtime_no_ports_overrides) if container
        files
      end

      def runtime_no_ports_overrides
        files = [CONTAINER_NO_PORTS_OVERRIDE]
        dependency_services.each do |service_name|
          override = File.join(RUNTIME_OVERRIDE_DIR, "no-ports-#{service_name}.yml")
          files << override if File.exist?(override)
        end
        files
      end

      def app_service
        component_config.app_service.to_s
      end

      def selected_profiles(key, container: false)
        profiles = [key.to_s]
        profiles << "container" if container
        profiles.concat(dependency_services)
        profiles.uniq
      end

      def all_backend_profiles(container: false)
        profiles = configured_backends.map(&:to_s)
        profiles << "container" if container
        profiles.concat(dependency_services)
        profiles.uniq
      end

      def configured_backends
        configured = component_config.backends.map { |b| b.to_s.strip.downcase.to_sym }.reject(&:empty?)
        configured = BACKENDS.keys if configured.empty?
        invalid = configured - BACKENDS.keys
        abort_with("Unknown backends in .ontoportal-testkit.yml: #{invalid.join(", ")}. Supported: #{BACKENDS.keys.join(", ")}") unless invalid.empty?
        configured
      end

      # Every task that brings containers up funnels through here, so the host
      # port guards live here rather than at the call sites. That is also what
      # makes them correct for with_container_stack, which passes a narrowed
      # profile list — deriving the port set from the `profiles:` argument is
      # automatically right, where deriving it at the call site would not be.
      def compose_up(files:, profiles:, compose_scope:)
        ensure_testkit_initialized!
        bindings = configured_port_bindings(files: files, profiles: profiles, compose_scope: compose_scope)
        ensure_host_ports_available!(bindings, compose_scope: compose_scope)
        expected = bindings.map { |binding| binding[:port] }.uniq.sort

        compose_up_attempt!(
          files: files,
          profiles: profiles,
          compose_scope: compose_scope,
          force_recreate: env_true?("OPTK_TEST_DOCKER_FORCE_RECREATE")
        )

        missing = missing_published_ports(compose_scope: compose_scope, expected: expected)
        return if missing.empty?

        warn(
          "Project #{compose_scope} reported healthy but host port(s) #{missing.join(", ")} are not " \
          "published (expected #{expected.join(", ")}). Recreating containers to clear stale " \
          "bindings — see moby/moby#51758."
        )
        compose_up_attempt!(files: files, profiles: profiles, compose_scope: compose_scope, force_recreate: true)

        still_missing = missing_published_ports(compose_scope: compose_scope, expected: expected)
        return if still_missing.empty?

        abort_with(stale_bindings_message(compose_scope: compose_scope, expected: expected, missing: still_missing))
      end

      def compose_up_attempt!(files:, profiles:, compose_scope:, force_recreate:)
        up_flags = ["up", "-d", "--wait", "--wait-timeout", timeout.to_s]
        up_flags << "--force-recreate" if force_recreate
        cmd = [
          compose_base(files, compose_scope: compose_scope),
          profile_flags(profiles),
          up_flags.join(" ")
        ].reject(&:empty?).join(" ")

        return mark_compose_started!(compose_scope) if shell?(cmd)

        # The started flag stays unset on purpose: abort_with raises SystemExit,
        # so with_backend_compose's ensure runs, sees false, and skips a second
        # teardown. Cleanup already happened here.
        cleanup_failed_compose_up!(files: files, profiles: profiles, compose_scope: compose_scope)
        abort_with("docker compose up failed for project #{compose_scope}.")
      end

      # A failed `up` leaves containers in `created` state. Docker Engine
      # resurrects those with no networking attached at all on the next start
      # (moby/moby#51758, unfixed as of Engine 29.x), yielding a stack that passes
      # container-local healthchecks while publishing nothing on the host. So they
      # must not survive the failure that created them.
      def cleanup_failed_compose_up!(files:, profiles:, compose_scope:)
        if keep_containers?
          warn(
            "OPTK_KEEP_CONTAINERS=1: leaving partially created containers for project " \
            "#{compose_scope} in place. A later run may reuse them with stale port bindings " \
            "(moby/moby#51758). Clear them with: docker compose -p #{compose_scope} down"
          )
          return
        end

        puts "Removing partially created containers for project #{compose_scope}"
        # Non-strict: a cleanup failure must not mask the original `up` failure.
        compose_down(files: files, profiles: profiles, compose_scope: compose_scope, strict: false)
      end

      def compose_down(files:, compose_scope:, profiles: [], strict: true)
        return puts("OPTK_KEEP_CONTAINERS=1 set, skipping docker compose down") if keep_containers?

        cmd = [compose_base(files, compose_scope: compose_scope), profile_flags(profiles), "down"].reject(&:empty?).join(" ")
        strict ? shell!(cmd) : shell?(cmd)
      end

      # Resolved host port bindings for a compose selection, straight from
      # `docker compose config`. base.yml stays the single source of truth, and
      # :container mode yields [] for free because runtime/no-ports*.yml strip
      # every `ports` entry — so the guards below are inert there by construction.
      def configured_port_bindings(files:, profiles:, compose_scope:)
        cmd = [
          compose_base(files, compose_scope: compose_scope),
          profile_flags(profiles),
          "config --format json"
        ].reject(&:empty?).join(" ")

        out, ok = capture(cmd)
        # Not a false positive worth tolerating: `up` would fail on the same input.
        abort_with("Could not resolve compose config for project #{compose_scope}:\n#{out}") unless ok

        parsed = parse_compose_config(out, compose_scope: compose_scope)
        services = parsed.is_a?(Hash) ? parsed["services"] : nil
        return [] unless services.is_a?(Hash)

        services.flat_map do |service_name, service|
          ports = service.is_a?(Hash) ? service["ports"] : nil
          Array(ports).filter_map do |port|
            next unless port.is_a?(Hash)

            published = port["published"].to_s[/\d+/]
            next unless published

            {port: published.to_i, host_ip: port["host_ip"].to_s, service: service_name}
          end
        end
      end

      def parse_compose_config(raw, compose_scope:)
        JSON.parse(raw.to_s)
      rescue JSON::ParserError => e
        abort_with("Could not parse compose config JSON for project #{compose_scope}: #{e.message}")
      end

      # Aborts when a host port the stack is about to publish is already taken.
      # Without this, the conflict surfaces as a bare compose bind error naming no
      # culprit — and on Engine 29.x it can leave containers that later come up
      # healthy but unreachable (moby/moby#51758).
      def ensure_host_ports_available!(bindings, compose_scope:)
        return if bindings.empty? || skip_port_checks?

        conflicts = bindings.uniq { |binding| binding[:port] }.filter_map do |binding|
          next unless host_port_taken?(binding)

          holder = docker_port_holder(binding[:port])
          # Our own already-running stack is not a conflict: `up[fs]` followed by
          # `test:docker:fs` is a legitimate sequence, and up/up:all deliberately
          # leave stacks running.
          next if holder && holder[:project] == compose_scope

          {port: binding[:port], service: binding[:service], holder: holder}
        end
        return if conflicts.empty?

        abort_with(port_conflict_message(conflicts, compose_scope: compose_scope))
      end

      def host_port_taken?(binding)
        probe_hosts(binding[:host_ip]).any? { |host| port_bind_fails?(host, binding[:port]) }
      end

      # base.yml publishes without a host_ip, and docker then binds both 0.0.0.0
      # and [::] — so probe both. An explicit host_ip is honored if one ever appears.
      def probe_hosts(host_ip)
        ip = host_ip.to_s.strip
        return [ip] unless ip.empty? || ip == "0.0.0.0" || ip == "::"

        ["0.0.0.0", "::"]
      end

      # Only EADDRINUSE counts as a conflict. IPv6 being unavailable
      # (EAFNOSUPPORT/EADDRNOTAVAIL) or a sandboxed bind (EACCES/EPERM) means
      # "unknown" — allow it through. A false positive blocks a legitimate run; a
      # false negative merely defers to compose, which now cleans up after itself.
      #
      # TCPServer sets SO_REUSEADDR, so a port in TIME_WAIT does not false-positive.
      def port_bind_fails?(host, port)
        server = TCPServer.new(host, port)
        false
      rescue Errno::EADDRINUSE
        true
      rescue SystemCallError
        false
      ensure
        server&.close
      end

      # Attribution only, and best effort. `--filter publish=` matches live
      # bindings, so nil just means "not a running docker container" — which is
      # still worth reporting, as a non-docker holder. Never let a docker failure
      # here block a run.
      def docker_port_holder(port)
        template = '{{.Names}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}'
        out, ok = capture("docker ps --filter publish=#{port} --format #{Shellwords.escape(template)}")
        return nil unless ok

        line = out.lines.map(&:strip).reject(&:empty?).first
        return nil unless line

        name, project, service = line.split("|", 3)
        {name: name.to_s, project: project.to_s, service: service.to_s}
      end

      def port_conflict_message(conflicts, compose_scope:)
        lines = ["Host port conflict(s) detected before `docker compose up` (project #{compose_scope}):", ""]
        conflicts.each { |conflict| lines << port_conflict_line(conflict) }

        projects = conflicts.filter_map { |conflict| conflict[:holder]&.fetch(:project) }.reject(&:empty?).uniq
        lines << ""
        if projects.empty?
          lines << "Free those ports, then retry."
        else
          lines << "Free those ports, or stop the other stack(s):"
          projects.each { |project| lines << "  docker compose -p #{project} down" }
        end

        lines << ""
        lines << "Container-mode tasks publish no host ports and are unaffected:"
        lines << "  bundle exec rake test:docker:#{default_backend}:container"
        lines << ""
        lines << "Override with OPTK_TEST_DOCKER_SKIP_PORT_CHECKS=1 (compose up will then fail on bind)."
        lines.join("\n")
      end

      def port_conflict_line(conflict)
        holder = conflict[:holder]
        return format("  %-6s held by a process outside docker", conflict[:port]) if holder.nil? || holder[:name].empty?

        details = ["compose project: #{holder[:project].empty? ? "none" : holder[:project]}"]
        details << "service: #{holder[:service]}" unless holder[:service].empty?
        format("  %-6s held by container %s (%s)", conflict[:port], holder[:name], details.join(", "))
      end

      # Expected host ports that are not actually published after `up`.
      #
      # Fails open at every step — a bug here would silently force-recreate on
      # every run, doubling the cost of stacks like GraphDB that re-initialize
      # from scratch. Compares "missing", never "extra", so adding a service to
      # base.yml cannot false-positive.
      def missing_published_ports(compose_scope:, expected:)
        return [] if expected.empty? || skip_port_checks?

        out, ok = capture("docker compose -p #{Shellwords.escape(compose_scope)} ps --format json")
        return [] unless ok

        containers = parse_compose_json_stream(out)
        return [] if containers.empty?

        actual = containers
          .flat_map { |container| Array(container["Publishers"]) }
          .filter_map { |publisher| publisher["PublishedPort"].to_i.nonzero? if publisher.is_a?(Hash) }
          .uniq
        expected - actual
      end

      def stale_bindings_message(compose_scope:, expected:, missing:)
        <<~MESSAGE
          Project #{compose_scope} came up but host port(s) #{missing.join(", ")} are still not
          published (expected #{expected.join(", ")}) even after --force-recreate.

          This is the signature of moby/moby#51758: a container whose first start failed on a
          port conflict loses its network config, and every later start attaches no networking
          at all. Container-local healthchecks still pass, so compose reports the stack healthy
          while nothing is reachable from the host.

          Clear the project and retry:
            docker compose -p #{compose_scope} down

          Skip this check with OPTK_TEST_DOCKER_SKIP_PORT_CHECKS=1.
        MESSAGE
      end

      def mark_compose_started!(compose_scope)
        @started_compose_scopes[compose_scope] = true
      end

      def compose_started?(compose_scope)
        @started_compose_scopes[compose_scope] == true
      end

      def apply_host_env(key)
        cfg!(key)[:host_env].each { |k, v| ENV[k] = v }
      end

      def run_host_tests(key)
        apply_host_env(key)
        files = compose_files_for(key, container: false)
        profiles = selected_profiles(key, container: false)
        compose_scope = compose_scope_name(key: key, container: false)

        compose_up(files: files, profiles: profiles, compose_scope: compose_scope)
        with_default_testopts { Rake::Task["test"].invoke }
      end

      def run_container_tests(key)
        # Pre-create the host coverage dir so the bind mount in base.yml lands on
        # a user-owned dir instead of one docker creates as root.
        FileUtils.mkdir_p("coverage")
        with_container_stack(key) do |files:, profiles:, compose_scope:, run_flags:|
          shell!(
            "#{compose_base(files, compose_scope: compose_scope)} #{profile_flags(profiles)} " \
            "run --rm #{run_flags} #{app_service} bundle exec rake test #{container_test_rake_args}"
          )
        end
      end

      def container_test_rake_args
        args = []
        test = ENV["TEST"]

        args << "TEST=#{Shellwords.escape(test)}" if test && !test.strip.empty?
        args << "TESTOPTS=#{Shellwords.escape(effective_testopts)}"

        args.join(" ")
      end

      def effective_testopts
        raw = ENV["TESTOPTS"]
        return "--verbose" if raw.nil? || raw.strip.empty?

        raw
      end

      def with_default_testopts
        previous = ENV["TESTOPTS"]
        ENV["TESTOPTS"] = effective_testopts
        yield
      ensure
        if previous.nil?
          ENV.delete("TESTOPTS")
        else
          ENV["TESTOPTS"] = previous
        end
      end

      def run_container_shell(key)
        with_container_stack(key) do |files:, profiles:, compose_scope:, run_flags:|
          shell!(
            "#{compose_base(files, compose_scope: compose_scope)} #{profile_flags(profiles)} " \
            "run --rm #{run_flags} #{app_service} bash"
          )
        end
      end

      def with_container_stack(key)
        override = backend_override_for(key)
        abort_with("Missing compose override file: #{override}") unless File.exist?(override)
        abort_with("Missing compose override file: #{CONTAINER_NO_PORTS_OVERRIDE}") unless File.exist?(CONTAINER_NO_PORTS_OVERRIDE)

        files = compose_files_for(key, container: true)
        profiles = selected_profiles(key, container: true)
        compose_scope = compose_scope_name(key: key, container: true)
        # Bring up only dependency services; the test service itself is started via
        # `docker compose run` so we don't run duplicate test containers.
        up_profiles = profiles.reject { |profile| profile == "container" }
        compose_up(files: files, profiles: up_profiles, compose_scope: compose_scope)

        run_flags = container_run_flags(compose_scope: compose_scope)
        yield(files: files, profiles: profiles, compose_scope: compose_scope, run_flags: run_flags)
      end

      def container_run_flags(compose_scope:)
        flags = []
        flags << "--build" if container_build_enabled?
        flags.concat(container_mount_flags(compose_scope: compose_scope))
        flags.join(" ")
      end

      def container_build_enabled?
        return false if container_dev_mode?

        env_true?("OPTK_TEST_DOCKER_CONTAINER_BUILD", default: true)
      end

      def container_dev_mode?
        env_true?("OPTK_TEST_DOCKER_CONTAINER_DEV_MODE", default: false)
      end

      def container_mount_workdir_enabled?
        return true if container_dev_mode?

        env_true?("OPTK_TEST_DOCKER_CONTAINER_MOUNT_WORKDIR", default: false)
      end

      def container_bundle_volume_enabled?
        return true if container_dev_mode?

        env_true?("OPTK_TEST_DOCKER_CONTAINER_BUNDLE_VOLUME", default: false)
      end

      def container_mount_flags(compose_scope:)
        flags = []
        if container_mount_workdir_enabled?
          flags << "-v #{Shellwords.escape("#{Dir.pwd}:/app")}"
        end
        if container_bundle_volume_enabled?
          flags << "-v #{Shellwords.escape("#{compose_scope}-bundle:/usr/local/bundle")}"
        end
        flags
      end

      def with_backend_compose(key, container:)
        files = compose_files_for(key, container: container)
        compose_scope = compose_scope_name(key: key, container: container)
        yield(files, compose_scope)
      ensure
        if files && compose_scope && compose_started?(compose_scope)
          compose_down(files: files, profiles: selected_profiles(key, container: container), compose_scope: compose_scope)
        end
      end

      def run_backends_in_parallel(task_suffix:)
        backends = configured_backends.map(&:to_s)
        children = {}

        backends.each do |backend|
          cmd = [RbConfig.ruby, "-S", "bundle", "exec", "rake", "test:docker:#{backend}:#{task_suffix}"]
          puts "Starting [#{backend}]: #{cmd.join(" ")}"
          pid = spawn(*cmd, chdir: Dir.pwd, out: $stdout, err: $stderr)
          children[pid] = backend
        end

        failures = []
        children.each_key do |pid|
          _pid, status = Process.wait2(pid)
          backend = children[pid]
          if status.success?
            puts "Completed [#{backend}] successfully"
          else
            failures << backend
            puts "Failed [#{backend}] with exit status #{status.exitstatus}"
          end
        end

        abort_with("Parallel backend run failed: #{failures.join(", ")}") unless failures.empty?
      end
    end
  end
end
