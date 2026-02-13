require_relative "testkit/version"
require_relative "testkit/component_config"

module Ontoportal
  module Testkit
    def self.root
      File.expand_path("../..", __dir__)
    end
  end
end
