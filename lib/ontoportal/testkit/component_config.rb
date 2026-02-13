require "yaml"

module Ontoportal
  module Testkit
    class ComponentConfig
      DEFAULT_PATH = ".ontoportal-test.yml".freeze

      attr_reader :path, :raw

      def initialize(path = DEFAULT_PATH)
        @path = path
        @raw = File.exist?(path) ? (YAML.load_file(path) || {}) : {}
      end

      def component_name
        raw.fetch("component_name", File.basename(Dir.pwd))
      end

      def app_service
        raw.fetch("app_service", "test-linux")
      end

      def backends
        Array(raw.fetch("backends", %w[fs ag vo gd]))
      end

      def dependency_services
        Array(raw.fetch("dependency_services", []))
      end
    end
  end
end
