require "rake"
require_relative "../testkit"

unless defined?(Ontoportal::Testkit::TASKS_FILE_LOADED)
  module Ontoportal
    module Testkit
      TASKS_FILE_LOADED = true

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
end
