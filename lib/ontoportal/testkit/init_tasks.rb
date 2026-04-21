require "fileutils"
require "erb"
require "tempfile"
require_relative "component_config"

module Ontoportal
  module Testkit
    # Scaffolds testkit files (component config, Dockerfile, rake loader, CI
    # workflow) into a consumer repo. Helpers live here so they do not leak
    # onto the Object namespace in consumer processes.
    class InitTasks
      FORCE_VALUES = %w[1 true yes force].freeze

      def run(force_arg: nil)
        force = FORCE_VALUES.include?(force_arg.to_s.strip.downcase)
        targets = scaffold_targets

        print_all_content_diffs(targets) unless force

        written = []
        skipped = []
        unchanged = []

        targets.each do |target|
          path = target[:path]
          content = target[:content]

          if File.exist?(path) && File.read(path) == content
            unchanged << path
            next
          end

          should_write = force || !File.exist?(path) || confirm_overwrite(path)
          if should_write
            dir = File.dirname(path)
            FileUtils.mkdir_p(dir) unless dir == "."
            File.write(path, content)
            written << path
          else
            skipped << path
          end
        end

        puts "Written: #{written.join(", ")}" unless written.empty?
        puts "Unchanged: #{unchanged.join(", ")}" unless unchanged.empty?
        puts "Skipped (already exists): #{skipped.join(", ")}" unless skipped.empty?

        unless force
          puts "Use force overwrite (zsh-safe):"
          puts "  bundle exec rake 'test:testkit:init[force]'"
        end
      end

      private

      def scaffold_targets
        component_name = (ENV["COMPONENT_NAME"] || File.basename(Dir.pwd)).to_s.strip
        app_service = (ENV["APP_SERVICE"] || "test-container").to_s.strip
        dependency_services = ENV.fetch("DEPENDENCY_SERVICES", "mgrep")
          .split(",")
          .map(&:strip)
          .reject(&:empty?)

        [
          {
            path: Ontoportal::Testkit::ComponentConfig::DEFAULT_PATH,
            content: render_template(
              template_path(".ontoportal-testkit.yml.erb"),
              component_name: component_name,
              app_service: app_service,
              dependency_services: dependency_services
            )
          },
          {
            path: "Dockerfile",
            content: read_template(template_path("Dockerfile"))
          },
          {
            path: File.join("rakelib", "ontoportal_testkit.rake"),
            content: read_template(template_path("rakelib", "ontoportal_testkit.rake"))
          },
          {
            path: File.join(".github", "workflows", "testkit-unit-tests.yml"),
            content: read_template(template_path(".github", "workflows", "testkit-unit-tests.yml"))
          }
        ]
      end

      def template_path(*parts)
        File.join(Ontoportal::Testkit.root, "templates", "init", *parts)
      end

      def confirm_overwrite(path)
        $stdout.print("`#{path}` exists. Overwrite? [y/N]: ")
        answer = $stdin.gets
        return false if answer.nil?

        %w[y yes].include?(answer.strip.downcase)
      end

      def print_all_content_diffs(targets)
        targets.each do |target|
          path = target[:path]
          next unless File.exist?(path)

          print_content_diff(path, target[:content])
        end
      end

      def print_content_diff(path, new_content)
        current_content = File.read(path)
        return if current_content == new_content

        Tempfile.create(["existing-", File.extname(path)]) do |existing|
          Tempfile.create(["generated-", File.extname(path)]) do |generated|
            existing.write(current_content)
            existing.flush
            generated.write(new_content)
            generated.flush

            puts "\nDiff for #{path}:"
            system("diff", "-u",
              "--label", "existing/#{path}", existing.path,
              "--label", "generated/#{path}", generated.path)
            puts
          end
        end
      end

      def read_template(path)
        abort("Missing init template: #{path}") unless File.exist?(path)
        File.read(path)
      end

      def render_template(path, vars = {})
        ERB.new(read_template(path), trim_mode: "-").result_with_hash(vars)
      end
    end
  end
end
