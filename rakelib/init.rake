require "fileutils"
require "erb"
require "tempfile"

namespace :test do
  namespace :testkit do
    desc "Initialize testkit files in the current component (args: force)"
    task :init, [:force] do |_t, args|
      force_values = %w[1 true yes force]
      force_arg = args[:force].to_s.strip.downcase
      force = force_values.include?(force_arg)
      component_name = (ENV["COMPONENT_NAME"] || File.basename(Dir.pwd)).to_s.strip
      app_service = (ENV["APP_SERVICE"] || "test-container").to_s.strip

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
      unchanged = []
      targets = [
        { path: config_path, content: config_content },
        { path: dockerfile_path, content: dockerfile_content },
        { path: rake_loader_path, content: rake_loader_content },
        { path: workflow_path, content: workflow_content }
      ]

      print_all_content_diffs(targets) unless force

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
  end
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

def read_template(template_path)
  abort("Missing init template: #{template_path}") unless File.exist?(template_path)
  File.read(template_path)
end

def render_template(template_path, vars = {})
  template = read_template(template_path)
  ERB.new(template, trim_mode: "-").result_with_hash(vars)
end
