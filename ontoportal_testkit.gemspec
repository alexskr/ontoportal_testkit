require_relative "lib/ontoportal/testkit/version"

Gem::Specification.new do |spec|
  spec.name = "ontoportal_testkit"
  spec.version = Ontoportal::Testkit::VERSION
  spec.authors = ["NCBO"]
  spec.summary = "Shared Docker-backed development tooling for OntoPortal components"
  spec.description = "Reusable rake tasks and conventions for Docker-driven backend dependencies across related repos."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir[
    "README.md",
    "Rakefile",
    ".ontoportal-testkit.example.yml",
    "Dockerfile",
    "docker/**/*",
    "lib/**/*.rb",
    "rakelib/**/*.rake"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "rake", ">= 13.0"
end
