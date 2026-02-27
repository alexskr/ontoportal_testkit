require "fileutils"
require "tmpdir"

namespace :test do
  namespace :testkit do
    namespace :integration do
      desc "Run testkit smoke test against a real component checkout (env: OPTK_COMPONENT_PATH, OPTK_INTEGRATION_RAKE_TASK)"
      task :component do
        source_path = ENV["OPTK_COMPONENT_PATH"] || ENV["GOO_PATH"]
        abort("Set OPTK_COMPONENT_PATH (or GOO_PATH) to a local component checkout") if source_path.to_s.strip.empty?

        source_path = File.expand_path(source_path)
        abort("Component path does not exist: #{source_path}") unless Dir.exist?(source_path)

        gemfile = File.join(source_path, "Gemfile")
        abort("Expected Gemfile in component path: #{source_path}") unless File.exist?(gemfile)

        integration_task = (ENV["OPTK_INTEGRATION_RAKE_TASK"] || "test:docker:fs:container").to_s.strip
        integration_task = "test:docker:fs:container" if integration_task.empty?
        testkit_root = Ontoportal::Testkit.root

        Dir.mktmpdir("optk-component-smoke-") do |tmpdir|
          workdir = File.join(tmpdir, File.basename(source_path))
          FileUtils.cp_r(source_path, workdir)

          inject_local_testkit_gem!(File.join(workdir, "Gemfile"), testkit_root)

          run_or_abort!(%w[bundle install], chdir: workdir)
          run_or_abort!(["bundle", "exec", "rake", "test:testkit:init[force]"], chdir: workdir)
          run_or_abort!(%w[bundle exec rake -T test:docker], chdir: workdir)
          run_or_abort!(["bundle", "exec", "rake", integration_task], chdir: workdir)
        end
      end
    end
  end
end

def inject_local_testkit_gem!(gemfile_path, testkit_root)
  content = File.read(gemfile_path)
  return if content.match?(/gem ["']ontoportal_testkit["']/)

  File.open(gemfile_path, "a") do |f|
    f.puts
    f.puts "# Added by ontoportal_testkit integration smoke task"
    f.puts %(gem "ontoportal_testkit", path: "#{testkit_root}")
  end
end

def run_or_abort!(cmd, chdir:)
  cmd_display = cmd.join(" ")
  puts "Running in #{chdir}: #{cmd_display}"
  ok = system(*cmd, chdir: chdir)
  abort("Command failed (#{cmd_display})") unless ok
end
