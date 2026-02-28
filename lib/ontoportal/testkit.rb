require_relative "testkit/version"
require_relative "testkit/component_config"
require_relative "testkit/integration_config"

module Ontoportal
  module Testkit
    def self.root
      File.expand_path("../..", __dir__)
    end
  end
end
