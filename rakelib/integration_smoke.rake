require "ontoportal/testkit/compose_contract"
require "ontoportal/testkit/integration_tasks"

namespace :test do
  namespace :testkit do
    namespace :integration do
      runner = Ontoportal::Testkit::IntegrationTasks.new

      desc "Run testkit smoke test against a real component checkout (env: OPTK_COMPONENT_PATH, OPTK_COMPONENT_REPO_REF, OPTK_COMPONENT_REPO_BRANCH, OPTK_INTEGRATION_RAKE_TASKS)"
      task :component do
        runner.component(component_path_env: ENV["OPTK_COMPONENT_PATH"] || ENV["GOO_PATH"])
      end

      Ontoportal::Testkit::IntegrationTasks::REPO_TASKS.each do |repo_name|
        desc "Clone #{repo_name} and run testkit integration smoke (env: OPTK_COMPONENT_REPO_ORG, OPTK_COMPONENT_REPO_URL, OPTK_COMPONENT_REPO_REF, OPTK_COMPONENT_REPO_BRANCH, OPTK_INTEGRATION_RAKE_TASKS)"
        task repo_name do
          runner.repo(repo_name.to_s)
        end
      end

      desc "Run integration smoke for all components listed in .ontoportal-testkit.integration.yml components"
      task :configured do
        runner.configured
      end

      desc "Verify the packaged compose files publish the expected host ports (docker compose config only; creates nothing)"
      task :compose_ports do
        Ontoportal::Testkit::ComposeContract.new.run
      end
    end
  end
end
