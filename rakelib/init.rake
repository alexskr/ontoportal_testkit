require "fileutils"
require "erb"

namespace :test do
  namespace :testkit do
    desc "Initialize testkit files in the current component (args: force)"
    task :init, [:force] do |_t, args|
      force_values = %w[1 true yes force]
      force_arg = args[:force].to_s.strip.downcase
      force = force_values.include?(force_arg)
      component_name = (ENV["COMPONENT_NAME"] || File.basename(Dir.pwd)).to_s.strip
      app_service = (ENV["APP_SERVICE"] || "test-linux").to_s.strip

      config_path = Ontoportal::Testkit::ComponentConfig::DEFAULT_PATH
      dockerfile_path = "Dockerfile"
      rake_loader_path = File.join("rakelib", "ontoportal_testkit.rake")
      workflow_path = File.join(".github", "workflows", "testkit-unit-tests.yml")
      template_root = File.join(Ontoportal::Testkit.root, "templates", "init")

      dependency_services = ENV.fetch("DEPENDENCY_SERVICES", "")
        .split(",")
        .map(&:strip)
        .reject(&:empty?)
      config_content = render_template(
        File.join(template_root, ".ontoportal-testkit.yml.erb"),
        component_name: component_name,
        app_service: app_service,
        dependency_services: dependency_services
      )
      dockerfile_content = read_template(File.join(template_root, "Dockerfile"))
      rake_loader_content = read_template(File.join(template_root, "rakelib", "ontoportal_testkit.rake"))
      workflow_content = read_template(File.join(template_root, ".github", "workflows", "testkit-unit-tests.yml"))

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
        File.write(dockerfile_path, dockerfile_content)
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

      puts "Written: #{written.join(", ")}" unless written.empty?
      puts "Skipped (already exists): #{skipped.join(", ")}" unless skipped.empty?
      unless force
        puts "Use force overwrite (zsh-safe):"
        puts "  bundle exec rake 'test:testkit:init[force]'"
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

def read_template(template_path)
  abort("Missing init template: #{template_path}") unless File.exist?(template_path)
  File.read(template_path)
end

def render_template(template_path, vars = {})
  template = read_template(template_path)
  ERB.new(template, trim_mode: "-").result_with_hash(vars)
end
