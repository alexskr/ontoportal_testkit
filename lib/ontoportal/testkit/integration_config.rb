require "yaml"

module Ontoportal
  module Testkit
    class IntegrationConfig
      DEFAULT_PATH = ".ontoportal-testkit.integration.yml".freeze

      attr_reader :path, :raw

      def initialize(path = nil)
        @path = path || ENV["OPTK_INTEGRATION_CONFIG_PATH"] || File.join(Ontoportal::Testkit.root, DEFAULT_PATH)
        @raw = File.exist?(@path) ? load_yaml(@path) : {}
      end

      def repo_org
        raw.fetch("repo_org", "ncbo").to_s.strip
      end

      def components
        Array(raw.fetch("components", %w[goo ontologies_linked_data ontologies_api]))
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
