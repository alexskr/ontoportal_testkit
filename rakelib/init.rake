require "fileutils"

namespace :test do
  namespace :testkit do
    desc "Initialize testkit files in the current component (args: force)"
    task :init, [:force] do |_t, args|
      force_values = %w[1 true yes force]
      force_arg = args[:force].to_s.strip.downcase
      force_env = ENV["FORCE"].to_s.strip.downcase
      force = force_values.include?(force_arg) || force_values.include?(force_env)
      component_name = (ENV["COMPONENT_NAME"] || File.basename(Dir.pwd)).to_s.strip
      app_service = (ENV["APP_SERVICE"] || "test-linux").to_s.strip

      config_path = Ontoportal::Testkit::ComponentConfig::DEFAULT_PATH
      dockerfile_path = "Dockerfile"
      rake_loader_path = File.join("rakelib", "ontoportal_testkit.rake")
      workflow_path = File.join(".github", "workflows", "testkit-unit-tests.yml")
      template_dockerfile = File.join(Ontoportal::Testkit.root, "Dockerfile")
      rake_loader_content = <<~RUBY
        # Loads shared OntoPortal testkit rake tasks into this component.
        require "ontoportal/testkit/tasks"
      RUBY
      workflow_content = <<~'YAML'
        name: Docker Unit Tests

        on:
          push:
            branches:
              - '**'
            tags-ignore:
              - '**'
          pull_request:

        jobs:
          prepare:
            runs-on: ubuntu-latest
            outputs:
              backends: ${{ steps.cfg.outputs.backends }}
            steps:
              - uses: actions/checkout@v4

              - id: cfg
                name: Read backend matrix from .ontoportal-testkit.yml
                run: |
                  BACKENDS=$(ruby -ryaml -rjson -e 'c=YAML.safe_load_file(".ontoportal-testkit.yml") || {}; b=c["backends"] || %w[fs ag vo gd]; puts JSON.generate(b)')
                  echo "backends=$BACKENDS" >> "$GITHUB_OUTPUT"

          test:
            needs: prepare
            runs-on: ubuntu-latest
            timeout-minutes: 45
            strategy:
              fail-fast: false
              matrix:
                backend: ${{ fromJson(needs.prepare.outputs.backends) }}

            steps:
              - uses: actions/checkout@v4

              - name: Set up Ruby from .ruby-version
                uses: ruby/setup-ruby@v1
                with:
                  ruby-version: .ruby-version
                  bundler-cache: true

              - name: Run unit tests in linux container
                env:
                  CI: "true"
                  TESTOPTS: "-v"
                run: bundle exec rake test:docker:${{ matrix.backend }}:linux

              - name: Upload coverage reports to Codecov
                uses: codecov/codecov-action@v5
                with:
                  token: ${{ secrets.CODECOV_TOKEN }}
                  flags: unittests,${{ matrix.backend }}
                  verbose: true
                  fail_ci_if_error: false
      YAML

      dependency_services = ENV.fetch("DEPENDENCY_SERVICES", "")
                               .split(",")
                               .map(&:strip)
                               .reject(&:empty?)

      config_content = <<~YAML
        component_name: #{component_name}
        app_service: #{app_service}
        backends:
          - fs
          - ag
          - vo
          - gd
        dependency_services: #{dependency_services.empty? ? "[]" : ""}
      YAML

      unless dependency_services.empty?
        config_content << dependency_services.map { |svc| "  - #{svc}" }.join("\n")
        config_content << "\n"
      end

      written = []
      skipped = []

      should_write = force || !File.exist?(config_path) || confirm_overwrite(config_path)
      if should_write
        File.write(config_path, config_content)
        written << config_path
      else
        skipped << config_path
      end

      should_write = force || !File.exist?(dockerfile_path) || confirm_overwrite(dockerfile_path)
      if should_write
        abort("Missing Dockerfile template: #{template_dockerfile}") unless File.exist?(template_dockerfile)
        File.write(dockerfile_path, File.read(template_dockerfile))
        written << dockerfile_path
      else
        skipped << dockerfile_path
      end

      should_write = force || !File.exist?(rake_loader_path) || confirm_overwrite(rake_loader_path)
      if should_write
        FileUtils.mkdir_p("rakelib")
        File.write(rake_loader_path, rake_loader_content)
        written << rake_loader_path
      else
        skipped << rake_loader_path
      end

      should_write = force || !File.exist?(workflow_path) || confirm_overwrite(workflow_path)
      if should_write
        FileUtils.mkdir_p(File.dirname(workflow_path))
        File.write(workflow_path, workflow_content)
        written << workflow_path
      else
        skipped << workflow_path
      end

      puts "Written: #{written.join(', ')}" unless written.empty?
      puts "Skipped (already exists): #{skipped.join(', ')}" unless skipped.empty?
      unless force
        puts "Use force overwrite (zsh-safe):"
        puts "  bundle exec rake 'test:testkit:init[force]'"
        puts "  FORCE=1 bundle exec rake test:testkit:init"
      end
    end
  end
end

def confirm_overwrite(path)
  $stdout.print("`#{path}` exists. Overwrite? [y/N]: ")
  answer = $stdin.gets
  return false if answer.nil?

  %w[y yes].include?(answer.strip.downcase)
end
