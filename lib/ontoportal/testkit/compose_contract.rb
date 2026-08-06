require_relative "docker_tasks"

module Ontoportal
  module Testkit
    # Maintainer-only contract check over the packaged compose files.
    #
    # Asserts the host port surface of every backend in both modes, derived from
    # `docker compose config` via DockerTasks#published_ports_for — the same code
    # path the port preflight uses, so the two cannot drift apart.
    #
    # Creates no containers, binds no ports, pulls no images, and needs no consumer
    # scaffold (`config` resolves fine without a Dockerfile or
    # .ontoportal-testkit.yml), so it is safe to run anywhere docker is installed.
    #
    # Not loaded by consumer repos: required from rakelib/integration_smoke.rake,
    # which is deliberately absent from COMPONENT_TASK_FILES.
    class ComposeContract
      # Host ports each backend publishes in host-Ruby mode. Duplicating them here
      # is the point — this literal *is* the contract docker/compose/base.yml must
      # satisfy, and the whole value of the check is that it fails when the two
      # disagree.
      HOST_PORTS = {
        fs: [6379, 8983, 9000],
        ag: [6379, 8983, 10035],
        vo: [1111, 6379, 8890, 8983],
        gd: [6379, 7200, 7300, 8983]
      }.freeze

      # Union across all four backends: what `test:docker:up:all` needs free.
      ALL_BACKENDS_HOST_PORTS = [1111, 6379, 7200, 7300, 8890, 8983, 9000, 10035].freeze

      MGREP_PORT = 55556

      # "" exercises the no-dependency-services path. It resolves to [] because
      # dependency_services falls back to ComponentConfig, and this gem root has no
      # .ontoportal-testkit.yml.
      DEPENDENCY_PERMUTATIONS = ["", "mgrep"].freeze

      def run
        failures = DEPENDENCY_PERMUTATIONS.flat_map do |services|
          with_dependency_services(services) { check_permutation(services) }
        end

        if failures.empty?
          puts "Compose port contract OK across #{DEPENDENCY_PERMUTATIONS.size} dependency permutation(s)."
          return
        end

        message = ["Compose port contract violated (#{failures.size} failure(s)):"]
        message.concat(failures.map { |failure| "  - #{failure}" })
        abort(message.join("\n"))
      end

      private

      def check_permutation(services)
        label = services.empty? ? "no dependency services" : "dependency services: #{services}"
        extra = services.split(",").map(&:strip).include?("mgrep") ? [MGREP_PORT] : []
        runner = Ontoportal::Testkit::DockerTasks.new
        failures = []

        HOST_PORTS.each_key do |key|
          failures.concat(check_backend(runner, key: key, extra: extra, label: label))
        end

        expected_all = (ALL_BACKENDS_HOST_PORTS + extra).uniq.sort
        actual_all = runner.published_ports_for(all_backends: true, container: false)
        unless actual_all == expected_all
          failures << "[#{label}] host mode, all backends: expected #{expected_all.inspect}, " \
                      "got #{actual_all.inspect} — test:docker:up:all needs exactly these free"
        end

        actual_all_container = runner.published_ports_for(all_backends: true, container: true)
        unless actual_all_container.empty?
          failures << "[#{label}] container mode, all backends: expected no published ports, " \
                      "got #{actual_all_container.inspect}"
        end

        failures
      end

      def check_backend(runner, key:, extra:, label:)
        failures = []

        expected_host = (HOST_PORTS.fetch(key) + extra).uniq.sort
        actual_host = runner.published_ports_for(key: key, container: false)
        unless actual_host == expected_host
          failures << "[#{label}] host mode #{key}: expected #{expected_host.inspect}, got #{actual_host.inspect}"
        end

        actual_container = runner.published_ports_for(key: key, container: true)
        unless actual_container.empty?
          failures << "[#{label}] container mode #{key}: expected no published ports, got " \
                      "#{actual_container.inspect} — runtime/no-ports.yml needs `ports: !override []` " \
                      "for every service base.yml publishes (a bare `ports: []` is a silent no-op)"
        end

        # Guards base.yml <-> BACKENDS drift, which would silently point host tests
        # at a port nothing publishes.
        goo_port = Ontoportal::Testkit::DockerTasks::BACKENDS
          .fetch(key).fetch(:host_env).fetch("GOO_PORT").to_i
        unless actual_host.include?(goo_port)
          failures << "[#{label}] backend #{key}: BACKENDS GOO_PORT=#{goo_port} is not published in " \
                      "host mode (#{actual_host.inspect}) — base.yml and BACKENDS have drifted"
        end

        failures
      end

      def with_dependency_services(services)
        previous = ENV["OPTK_TEST_DOCKER_DEPENDENCY_SERVICES"]
        ENV["OPTK_TEST_DOCKER_DEPENDENCY_SERVICES"] = services
        yield
      ensure
        if previous.nil?
          ENV.delete("OPTK_TEST_DOCKER_DEPENDENCY_SERVICES")
        else
          ENV["OPTK_TEST_DOCKER_DEPENDENCY_SERVICES"] = previous
        end
      end
    end
  end
end
