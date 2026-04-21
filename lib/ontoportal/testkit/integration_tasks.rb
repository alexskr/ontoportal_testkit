require "fileutils"
require "tmpdir"
require_relative "integration_config"

module Ontoportal
  module Testkit
    # Maintainer-only integration smoke runner. Clones or copies a consumer
    # component, points it at this testkit checkout, then invokes one or more
    # rake tasks inside the component. Not loaded by consumer repos via
    # `require "ontoportal/testkit/tasks"` — see COMPONENT_TASK_FILES.
    class IntegrationTasks
      REPO_TASKS = %i[goo ontologies_linked_data ontologies_api].freeze

      def component(component_path_env:)
        source_path = component_path_env.to_s
        abort("Set OPTK_COMPONENT_PATH (or GOO_PATH) to a local component checkout") if source_path.strip.empty?

        source_path = File.expand_path(source_path)
        abort("Component path does not exist: #{source_path}") unless Dir.exist?(source_path)
        gemfile = File.join(source_path, "Gemfile")
        abort("Expected Gemfile in component path: #{source_path}") unless File.exist?(gemfile)

        Dir.mktmpdir("optk-component-smoke-") do |tmpdir|
          workdir = File.join(tmpdir, File.basename(source_path))
          FileUtils.cp_r(source_path, workdir)
          checkout_repo_selector!(workdir: workdir, repo_ref: repo_ref, repo_branch: repo_branch)
          run_component_integration!(workdir: workdir)
        end
      end

      def repo(repo_name)
        url = (ENV["OPTK_COMPONENT_REPO_URL"] || "https://github.com/#{repo_org}/#{repo_name}").to_s.strip

        Dir.mktmpdir("optk-#{repo_name}-smoke-") do |tmpdir|
          workdir = File.join(tmpdir, "component")
          clone_component_repo!(repo_url: url, workdir: workdir)
          run_component_integration!(workdir: workdir)
        end
      end

      def configured
        components = integration_components
        abort("No integration components configured. Set components in .ontoportal-testkit.integration.yml") if components.empty?
        components.each { |name| repo(name) }
      end

      private

      def integration_tasks
        raw = (ENV["OPTK_INTEGRATION_RAKE_TASKS"] || "test:docker:fs:container").to_s
        tasks = raw.split(",").map(&:strip).reject(&:empty?)
        abort("No integration tasks resolved. Set OPTK_INTEGRATION_RAKE_TASKS.") if tasks.empty?
        tasks
      end

      def repo_org
        env_value = ENV["OPTK_COMPONENT_REPO_ORG"].to_s.strip
        return env_value unless env_value.empty?

        integration_config.repo_org
      end

      def repo_ref
        ENV["OPTK_COMPONENT_REPO_REF"].to_s.strip
      end

      def repo_branch
        ENV["OPTK_COMPONENT_REPO_BRANCH"].to_s.strip
      end

      def integration_components
        integration_config.components.map(&:to_s).map(&:strip).reject(&:empty?).uniq
      end

      def integration_config
        @integration_config ||= Ontoportal::Testkit::IntegrationConfig.new
      end

      def testkit_root
        Ontoportal::Testkit.root
      end

      def clone_component_repo!(repo_url:, workdir:)
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

      def run_component_integration!(workdir:)
        ensure_local_testkit_gem!(File.join(workdir, "Gemfile"))
        run_or_abort!(%w[bundle install], chdir: workdir)
        run_testkit_task_or_abort!(task_name: "test:testkit:init[force]", chdir: workdir)

        integration_tasks.each do |task_name|
          run_testkit_task_or_abort!(task_name: task_name, chdir: workdir)
        end
      end

      def run_testkit_task_or_abort!(task_name:, chdir:)
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

        run_or_abort!(
          ["bundle", "exec", "ruby", "-I", File.join(testkit_root, "lib"), "-e", ruby_cmd],
          chdir: chdir,
          env: {"OPTK_TASK" => task_name}
        )
      end

      def ensure_local_testkit_gem!(gemfile_path)
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
    end
  end
end
