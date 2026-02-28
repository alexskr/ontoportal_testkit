require "rake"
require_relative "../testkit"

unless defined?(Ontoportal::Testkit::TASKS_FILE_LOADED)
  module Ontoportal
    module Testkit
      TASKS_FILE_LOADED = true
      # Component-facing task import allowlist.
      # These files are loaded when a consumer repo does:
      #   require "ontoportal/testkit/tasks"
      # Keep integration/maintainer-only tasks out of this list.
      COMPONENT_TASK_FILES = %w[
        base_image.rake
        config.rake
        docker_based_test.rake
        init.rake
      ].freeze

      def self.load_tasks!
        return if defined?(@tasks_loaded) && @tasks_loaded

        # Rake does not auto-load task files from gem-internal rakelib.
        # We import selected task files explicitly into the consumer's Rake app.
        COMPONENT_TASK_FILES.each do |file_name|
          task_file = File.join(root, "rakelib", file_name)
          next unless File.exist?(task_file)

          Rake.application.add_import(task_file)
        end

        Rake.application.load_imports
        @tasks_loaded = true
      end
    end
  end

  Ontoportal::Testkit.load_tasks!
end
