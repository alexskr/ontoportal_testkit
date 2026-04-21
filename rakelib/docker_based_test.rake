require "ontoportal/testkit/docker_tasks"

# Docker compose driven unit test orchestration.
# Helpers, constants, and state all live on Ontoportal::Testkit::DockerTasks —
# this file is a thin task-definition shim so consumer components don't inherit
# ~40 helper methods on Object when they require the testkit tasks.
namespace :test do
  namespace :docker do
    runner = Ontoportal::Testkit::DockerTasks.new

    runner.backend_keys.each do |key|
      desc "Run unit tests with #{runner.backend_label(key)} backend (docker deps, host Ruby)"
      task key do
        runner.run_host_backend(key)
      end

      desc "Run unit tests with #{runner.backend_label(key)} backend (docker deps, linux container)"
      task "#{key}:container" do
        runner.run_container_backend(key)
      end

      desc "Run unit tests with #{runner.backend_label(key)} backend (linux container, dev mode)"
      task "#{key}:container:dev" do
        runner.run_container_backend_dev(key)
      ensure
        Rake::Task["test:docker:#{key}:container"].reenable
      end
    end

    desc "Run linux-container unit tests against all backends in parallel"
    task "all:container" do
      runner.run_all_container_parallel
    end

    desc "Run linux-container unit tests against all backends in parallel (dev mode)"
    task "all:container:dev" do
      runner.run_all_container_parallel(dev: true)
    end

    desc "Start a shell in the linux test container (default backend: fs)"
    task :shell, [:backend] do |_t, args|
      runner.open_shell(backend: args[:backend])
    end

    desc "Start a shell in the linux test container in dev mode (default backend: fs)"
    task "shell:dev", [:backend] do |_t, args|
      runner.open_shell_dev(backend: args[:backend])
    ensure
      Rake::Task["test:docker:shell"].reenable
    end

    desc "Start backend services for development (default backend: fs)"
    task :up, [:backend] do |_t, args|
      runner.up(backend: args[:backend])
    end

    desc "Start all backend services (ag, fs, vo, gd) and dependency services"
    task "up:all" do
      runner.up_all
    end

    desc "Stop backend services for development (optional arg: backend)"
    task :down, [:backend] do |_t, args|
      runner.down(backend: args[:backend])
    end
  end
end
