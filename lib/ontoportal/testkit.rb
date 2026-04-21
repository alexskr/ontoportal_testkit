require_relative "testkit/version"

module Ontoportal
  module Testkit
    def self.root
      File.expand_path("../..", __dir__)
    end
  end
end

require_relative "testkit/component_config"
require_relative "testkit/integration_config"
