require_relative "lib/ontoportal/testkit/version"

Gem::Specification.new do |spec|
  spec.name = "ontoportal_testkit"
  spec.version = Ontoportal::Testkit::VERSION
  spec.authors = ["Alex Skrenchuk"]
  spec.summary = "Shared Docker testkit and setup scaffolding for OntoPortal components"
  spec.description = "Provides reusable rake tasks, compose conventions, and init scaffolding for Docker-driven backend dependencies and test execution across OntoPortal components."
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
