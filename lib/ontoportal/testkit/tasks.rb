require "rake"
require_relative "../testkit"

module Ontoportal
  module Testkit
    def self.load_tasks!
      return if defined?(@tasks_loaded) && @tasks_loaded

      Dir[File.join(root, "rakelib", "*.rake")].sort.each do |task_file|
        Rake.application.add_import(task_file)
      end

      Rake.application.load_imports
      @tasks_loaded = true
    end
  end
end

Ontoportal::Testkit.load_tasks!

namespace :test do
  namespace :testkit do
    desc "Show loaded testkit component config"
    task :config do
      cfg = Ontoportal::Testkit::ComponentConfig.new
      puts "component_name: #{cfg.component_name}"
      puts "app_service: #{cfg.app_service}"
      puts "backends: #{cfg.backends.join(', ')}"
      puts "dependency_services: #{cfg.dependency_services.join(', ')}"
    end
  end
end
