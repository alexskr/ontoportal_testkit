require "rake"
require_relative "../testkit"

module Ontoportal
  module Testkit
    def self.load_tasks!
      return if defined?(@tasks_loaded) && @tasks_loaded

      Dir[File.join(root, "rakelib", "*.rake")].sort.each do |task_file|
        load task_file
      end

      @tasks_loaded = true
    end
  end
end

Ontoportal::Testkit.load_tasks!

namespace :test do
  namespace :testkit do
    desc "Show loaded testkit project config"
    task :config do
      cfg = Ontoportal::Testkit::ProjectConfig.new
      puts "project_name: #{cfg.project_name}"
      puts "app_service: #{cfg.app_service}"
      puts "backends: #{cfg.backends.join(', ')}"
      puts "optional_services: #{cfg.optional_services.join(', ')}"
    end
  end
end
