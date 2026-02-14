require "yaml"

module Ontoportal
  module Testkit
    class ComponentConfig
      DEFAULT_PATH = ".ontoportal-testkit.yml".freeze

      attr_reader :path, :raw

      def initialize(path = DEFAULT_PATH)
        @path = path
        @raw = File.exist?(path) ? load_yaml(path) : {}
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

      private

      def load_yaml(path)
        content = File.read(path)
        parsed = YAML.safe_load(content, permitted_classes: [], permitted_symbols: [], aliases: false)
        parsed.is_a?(Hash) ? parsed : {}
      rescue Psych::Exception => e
        raise ArgumentError, "Invalid YAML in #{path}: #{e.message}"
      end
    end
  end
end
