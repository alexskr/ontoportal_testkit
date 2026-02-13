require "yaml"

module Ontoportal
  module Testkit
    class ProjectConfig
      DEFAULT_PATH = ".ontoportal-test.yml".freeze

      attr_reader :path, :raw

      def initialize(path = DEFAULT_PATH)
        @path = path
        @raw = File.exist?(path) ? (YAML.load_file(path) || {}) : {}
      end

      def project_name
        raw.fetch("project_name", "unknown")
      end

      def app_service
        raw.fetch("app_service", "test-linux")
      end

      def backends
        Array(raw.fetch("backends", %w[fs ag vo gd]))
      end

      def optional_services
        Array(raw.fetch("optional_services", []))
      end
    end
  end
end
