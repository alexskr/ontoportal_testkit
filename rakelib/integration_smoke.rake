require "fileutils"
require "tmpdir"

namespace :test do
  namespace :testkit do
    namespace :integration do
      REPO_TASKS = {
        goo: "goo",
        ontologies_linked_data: "ontologies_linked_data",
        ontologies_api: "ontologies_api"
      }.freeze unless defined?(REPO_TASKS)

      desc "Run testkit smoke test against a real component checkout (env: OPTK_COMPONENT_PATH, OPTK_COMPONENT_REPO_REF, OPTK_COMPONENT_REPO_BRANCH, OPTK_INTEGRATION_RAKE_TASKS)"
      task :component do
        source_path = ENV["OPTK_COMPONENT_PATH"] || ENV["GOO_PATH"]
        abort("Set OPTK_COMPONENT_PATH (or GOO_PATH) to a local component checkout") if source_path.to_s.strip.empty?

        source_path = File.expand_path(source_path)
        abort("Component path does not exist: #{source_path}") unless Dir.exist?(source_path)

        gemfile = File.join(source_path, "Gemfile")
        abort("Expected Gemfile in component path: #{source_path}") unless File.exist?(gemfile)

        integration_tasks = integration_tasks_from_env
        repo_ref = ENV["OPTK_COMPONENT_REPO_REF"].to_s.strip
        repo_branch = ENV["OPTK_COMPONENT_REPO_BRANCH"].to_s.strip
        testkit_root = Ontoportal::Testkit.root

        Dir.mktmpdir("optk-component-smoke-") do |tmpdir|
          workdir = File.join(tmpdir, File.basename(source_path))
          FileUtils.cp_r(source_path, workdir)
          checkout_repo_selector!(workdir: workdir, repo_ref: repo_ref, repo_branch: repo_branch)

          run_component_integration!(workdir: workdir, testkit_root: testkit_root, integration_tasks: integration_tasks)
        end
      end

      REPO_TASKS.each do |task_name, repo_name|
        desc "Clone #{repo_name} and run testkit integration smoke (env: OPTK_COMPONENT_REPO_ORG, OPTK_COMPONENT_REPO_URL, OPTK_COMPONENT_REPO_REF, OPTK_COMPONENT_REPO_BRANCH, OPTK_INTEGRATION_RAKE_TASKS)"
        task task_name do
          repo_org = integration_repo_org_from_env_or_config
          repo_url = (ENV["OPTK_COMPONENT_REPO_URL"] || "https://github.com/#{repo_org}/#{repo_name}").to_s.strip
          repo_ref = ENV["OPTK_COMPONENT_REPO_REF"].to_s.strip
          repo_branch = ENV["OPTK_COMPONENT_REPO_BRANCH"].to_s.strip
          integration_tasks = integration_tasks_from_env
          testkit_root = Ontoportal::Testkit.root

          Dir.mktmpdir("optk-#{repo_name}-smoke-") do |tmpdir|
            workdir = File.join(tmpdir, "component")
            clone_component_repo!(repo_url: repo_url, repo_ref: repo_ref, repo_branch: repo_branch, workdir: workdir)
            run_component_integration!(workdir: workdir, testkit_root: testkit_root, integration_tasks: integration_tasks)
          end
        end
      end

      desc "Run integration smoke for all components listed in .ontoportal-testkit.integration.yml components"
      task :configured do
        components = integration_components_from_config
        abort("No integration components configured. Set components in .ontoportal-testkit.integration.yml") if components.empty?

        components.each do |repo_name|
          run_configured_component_smoke!(repo_name: repo_name)
        end
      end
    end
  end
end

def integration_tasks_from_env
  raw = (ENV["OPTK_INTEGRATION_RAKE_TASKS"] || "test:docker:fs:container").to_s
  tasks = raw.split(",").map(&:strip).reject(&:empty?)
  abort("No integration tasks resolved. Set OPTK_INTEGRATION_RAKE_TASKS.") if tasks.empty?
  tasks
end

def clone_component_repo!(repo_url:, repo_ref:, repo_branch:, workdir:)
  run_or_abort!(["git", "clone", "--depth", "1", repo_url, workdir], chdir: Dir.pwd)
  checkout_repo_selector!(workdir: workdir, repo_ref: repo_ref, repo_branch: repo_branch)
end

def checkout_repo_selector!(workdir:, repo_ref:, repo_branch:)
  if !repo_ref.empty?
    run_or_abort!(["git", "fetch", "--depth", "1", "origin", repo_ref], chdir: workdir)
    run_or_abort!(["git", "checkout", repo_ref], chdir: workdir)
    return
  end
  return if repo_branch.empty?

  run_or_abort!(["git", "fetch", "--depth", "1", "origin", repo_branch], chdir: workdir)
  run_or_abort!(["git", "checkout", "-B", repo_branch, "FETCH_HEAD"], chdir: workdir)
end

def run_component_integration!(workdir:, testkit_root:, integration_tasks:)
  ensure_local_testkit_gem!(File.join(workdir, "Gemfile"), testkit_root)
  run_or_abort!(%w[bundle install], chdir: workdir)
  run_testkit_task_or_abort!(task_name: "test:testkit:init[force]", testkit_root: testkit_root, chdir: workdir)

  integration_tasks.each do |task_name|
    run_testkit_task_or_abort!(task_name: task_name, testkit_root: testkit_root, chdir: workdir)
  end
end

def run_configured_component_smoke!(repo_name:)
  repo_org = integration_repo_org_from_env_or_config
  repo_url = (ENV["OPTK_COMPONENT_REPO_URL"] || "https://github.com/#{repo_org}/#{repo_name}").to_s.strip
  repo_ref = ENV["OPTK_COMPONENT_REPO_REF"].to_s.strip
  repo_branch = ENV["OPTK_COMPONENT_REPO_BRANCH"].to_s.strip
  integration_tasks = integration_tasks_from_env
  testkit_root = Ontoportal::Testkit.root

  Dir.mktmpdir("optk-#{repo_name}-smoke-") do |tmpdir|
    workdir = File.join(tmpdir, "component")
    clone_component_repo!(repo_url: repo_url, repo_ref: repo_ref, repo_branch: repo_branch, workdir: workdir)
    run_component_integration!(workdir: workdir, testkit_root: testkit_root, integration_tasks: integration_tasks)
  end
end

def integration_repo_org_from_env_or_config
  env_value = ENV["OPTK_COMPONENT_REPO_ORG"].to_s.strip
  return env_value unless env_value.empty?

  integration_config.repo_org
end

def integration_components_from_config
  integration_config.components.map(&:to_s).map(&:strip).reject(&:empty?).uniq
end

def integration_config
  @integration_config ||= Ontoportal::Testkit::IntegrationConfig.new
end

def run_testkit_task_or_abort!(task_name:, testkit_root:, chdir:)
  ruby_cmd = <<~RUBY
    require "rake"
    require "ontoportal/testkit/tasks"
    raw = ENV.fetch("OPTK_TASK")
    match = raw.match(/\\A([^\\[]+)\\[(.*)\\]\\z/)
    if match
      name = match[1]
      args = match[2].to_s.split(",").map(&:strip)
      Rake::Task[name].invoke(*args)
    else
      Rake::Task[raw].invoke
    end
  RUBY
  run_or_abort!(["bundle", "exec", "ruby", "-I", File.join(testkit_root, "lib"), "-e", ruby_cmd], chdir: chdir, env: { "OPTK_TASK" => task_name })
end

def ensure_local_testkit_gem!(gemfile_path, testkit_root)
  content = File.read(gemfile_path)
  local_decl = %(gem "ontoportal_testkit", path: "#{testkit_root}")

  if content.match?(/^\s*gem\s+["']ontoportal_testkit["'].*$/)
    updated = content.gsub(/^\s*gem\s+["']ontoportal_testkit["'].*$/, local_decl)
    File.write(gemfile_path, updated)
    return
  end

  File.open(gemfile_path, "a") do |f|
    f.puts
    f.puts "# Added by ontoportal_testkit integration smoke task"
    f.puts local_decl
  end
end

def run_or_abort!(cmd, chdir:, env: {})
  cmd_display = cmd.join(" ")
  puts "Running in #{chdir}: #{cmd_display}"
  ok = system(env, *cmd, chdir: chdir)
  abort("Command failed (#{cmd_display})") unless ok
end
