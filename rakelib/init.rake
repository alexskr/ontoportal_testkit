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
      template_dockerfile = File.join(Ontoportal::Testkit.root, "Dockerfile")
      rake_loader_content = <<~RUBY
        # Loads shared OntoPortal testkit rake tasks into this component.
        require "ontoportal/testkit/tasks"
      RUBY

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

      created = []
      skipped = []

      if !force && File.exist?(config_path)
        skipped << config_path
      else
        File.write(config_path, config_content)
        created << config_path
      end

      if !force && File.exist?(dockerfile_path)
        skipped << dockerfile_path
      else
        abort("Missing Dockerfile template: #{template_dockerfile}") unless File.exist?(template_dockerfile)
        File.write(dockerfile_path, File.read(template_dockerfile))
        created << dockerfile_path
      end

      if !force && File.exist?(rake_loader_path)
        skipped << rake_loader_path
      else
        FileUtils.mkdir_p("rakelib")
        File.write(rake_loader_path, rake_loader_content)
        created << rake_loader_path
      end

      puts "Created: #{created.join(', ')}" unless created.empty?
      puts "Skipped (already exists): #{skipped.join(', ')}" unless skipped.empty?
      unless force
        puts "Use force overwrite (zsh-safe):"
        puts "  bundle exec rake 'test:testkit:init[force]'"
        puts "  FORCE=1 bundle exec rake test:testkit:init"
      end
    end
  end
end
