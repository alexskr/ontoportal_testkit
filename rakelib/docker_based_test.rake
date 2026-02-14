require "rbconfig"
require "shellwords"

# Docker compose driven unit test orchestration
#
# Notes:
# - Backend names match compose profile names (ag, fs, vo, gd).
# - Hostnames are NOT set for host Ruby runs; config defaults to localhost.
# - Compose files are packaged under docker/compose/{base,backends,services,runtime}.
namespace :test do
  namespace :docker do
    TESTKIT_ROOT = Ontoportal::Testkit.root unless defined?(TESTKIT_ROOT)
    COMPOSE_ROOT = File.join(TESTKIT_ROOT, 'docker/compose') unless defined?(COMPOSE_ROOT)
    BASE_COMPOSE = File.join(COMPOSE_ROOT, 'base.yml') unless defined?(BASE_COMPOSE)
    BACKEND_OVERRIDE_DIR = File.join(COMPOSE_ROOT, 'backends') unless defined?(BACKEND_OVERRIDE_DIR)
    SERVICE_OVERRIDE_DIR = File.join(COMPOSE_ROOT, 'services') unless defined?(SERVICE_OVERRIDE_DIR)
    RUNTIME_OVERRIDE_DIR = File.join(COMPOSE_ROOT, 'runtime') unless defined?(RUNTIME_OVERRIDE_DIR)
    LINUX_NO_PORTS_OVERRIDE = File.join(RUNTIME_OVERRIDE_DIR, 'no-ports.yml') unless defined?(LINUX_NO_PORTS_OVERRIDE)
    TIMEOUT = (ENV['OP_TEST_DOCKER_TIMEOUT'] || '600').to_i unless defined?(TIMEOUT)
    DEFAULT_BACKEND = (ENV['OP_TEST_DOCKER_BACKEND'] || 'fs').to_sym unless defined?(DEFAULT_BACKEND)

    BACKENDS = {
      ag: {
        host_env: {
          'GOO_BACKEND_NAME' => 'ag',
          'GOO_PORT' => '10035',
          'GOO_PATH_QUERY' => '/repositories/ontoportal_test',
          'GOO_PATH_DATA' => '/repositories/ontoportal_test/statements',
          'GOO_PATH_UPDATE' => '/repositories/ontoportal_test/statements'
        }
      },
      fs: {
        host_env: {
          'GOO_BACKEND_NAME' => '4store',
          'GOO_PORT' => '9000',
          'GOO_PATH_QUERY' => '/sparql/',
          'GOO_PATH_DATA' => '/data/',
          'GOO_PATH_UPDATE' => '/update/'
        }
      },
      vo: {
        host_env: {
          'GOO_BACKEND_NAME' => 'virtuoso',
          'GOO_PORT' => '8890',
          'GOO_PATH_QUERY' => '/sparql',
          'GOO_PATH_DATA' => '/sparql',
          'GOO_PATH_UPDATE' => '/sparql'
        }
      },
      gd: {
        host_env: {
          'GOO_BACKEND_NAME' => 'graphdb',
          'GOO_PORT' => '7200',
          'GOO_PATH_QUERY' => '/repositories/ontoportal_test',
          'GOO_PATH_DATA' => '/repositories/ontoportal_test/statements',
          'GOO_PATH_UPDATE' => '/repositories/ontoportal_test/statements'
        }
      }
    }.freeze unless defined?(BACKENDS)

    def abort_with(msg)
      warn(msg)
      exit(1)
    end

    def shell!(cmd)
      puts "Running: #{cmd}"
      system(cmd) || abort_with("Command failed: #{cmd}")
    end

    def cfg!(key)
      cfg = BACKENDS[key]
      abort_with("Unknown backend key: #{key}. Supported: #{BACKENDS.keys.join(', ')}") unless cfg
      cfg
    end

    def component_config
      @component_config ||= Ontoportal::Testkit::ComponentConfig.new
    end

    def compose_files(*files)
      files.flatten.map { |f| "-f #{f}" }.join(' ')
    end

    def profile_flags(profiles)
      Array(profiles).map { |profile| "--profile #{profile}" }.join(' ')
    end

    def compose_scope_name(key: nil, linux: false)
      name = component_config.component_name.to_s.strip
      name = File.basename(Dir.pwd) if name.empty?

      scoped = [name, key&.to_s, (linux ? "linux" : nil)].compact.join("-")
      normalized = scoped.downcase.gsub(/[^a-z0-9_-]/, "-")
      normalized = "op-testkit" if normalized.empty?
      normalized
    end

    def compose_base(files, compose_scope:)
      component_dir = Shellwords.escape(Dir.pwd)
      "docker compose --project-directory #{component_dir} -p #{compose_scope} #{compose_files(files)}"
    end

    def backend_override_for(key)
      "#{BACKEND_OVERRIDE_DIR}/#{key}.yml"
    end

    def service_override_for(service_name)
      "#{SERVICE_OVERRIDE_DIR}/#{service_name}.yml"
    end

    def dependency_services
      env = ENV['OP_TEST_DOCKER_DEPENDENCY_SERVICES']
      return env.split(',').map(&:strip).reject(&:empty?) if env && !env.strip.empty?

      component_config.dependency_services.map(&:to_s)
    end

    def dependency_override_files
      dependency_services.map do |service_name|
        override = service_override_for(service_name)
        abort_with("Missing dependency service override file: #{override}") unless File.exist?(override)
        override
      end
    end

    def compose_files_for(key = nil, linux: false)
      files = [BASE_COMPOSE]
      files << backend_override_for(key) if linux && key
      files.concat(dependency_override_files)
      files << LINUX_NO_PORTS_OVERRIDE if linux
      files
    end

    def app_service
      component_config.app_service.to_s
    end

    def selected_profiles(key, linux: false)
      profiles = [key.to_s]
      profiles << "linux" if linux
      profiles.concat(dependency_services)
      profiles.uniq
    end

    def all_backend_profiles(linux: false)
      profiles = configured_backends.map(&:to_s)
      profiles << "linux" if linux
      profiles.concat(dependency_services)
      profiles.uniq
    end

    def configured_backends
      configured = component_config.backends.map { |b| b.to_s.strip.downcase.to_sym }.reject(&:empty?)
      configured = BACKENDS.keys if configured.empty?
      invalid = configured - BACKENDS.keys
      abort_with("Unknown backends in .ontoportal-testkit.yml: #{invalid.join(', ')}. Supported: #{BACKENDS.keys.join(', ')}") unless invalid.empty?
      configured
    end

    def compose_up(files:, profiles:, compose_scope:)
      shell!("#{compose_base(files, compose_scope: compose_scope)} #{profile_flags(profiles)} up -d --wait --wait-timeout #{TIMEOUT}")
    end

    def compose_down(files:, profiles: [], compose_scope:)
      return puts('OP_KEEP_CONTAINERS=1 set, skipping docker compose down') if ENV['OP_KEEP_CONTAINERS'] == '1'

      cmd = [compose_base(files, compose_scope: compose_scope), profile_flags(profiles), "down"].reject(&:empty?).join(' ')
      shell!(cmd)
    end

    def apply_host_env(key)
      cfg!(key)[:host_env].each { |k, v| ENV[k] = v }
    end

    def run_host_tests(key)
      apply_host_env(key)
      files = compose_files_for(key, linux: false)
      profiles = selected_profiles(key, linux: false)
      compose_scope = compose_scope_name(key: key, linux: false)

      compose_up(files: files, profiles: profiles, compose_scope: compose_scope)
      Rake::Task['test'].invoke
    end

    def run_linux_tests(key)
      override = backend_override_for(key)
      abort_with("Missing compose override file: #{override}") unless File.exist?(override)
      abort_with("Missing compose override file: #{LINUX_NO_PORTS_OVERRIDE}") unless File.exist?(LINUX_NO_PORTS_OVERRIDE)

      files = compose_files_for(key, linux: true)
      profiles = selected_profiles(key, linux: true)
      compose_scope = compose_scope_name(key: key, linux: true)
      compose_up(files: files, profiles: profiles, compose_scope: compose_scope)

      shell!(
        "#{compose_base(files, compose_scope: compose_scope)} #{profile_flags(profiles)} " \
        "run --rm --build #{app_service} bundle exec rake test #{linux_test_rake_args}"
      )
    end

    def linux_test_rake_args
      args = []
      test = ENV["TEST"]
      testopts = ENV["TESTOPTS"]

      args << "TEST=#{Shellwords.escape(test)}" if test && !test.strip.empty?
      if testopts && !testopts.strip.empty?
        args << "TESTOPTS=#{Shellwords.escape(testopts)}"
      else
        args << "TESTOPTS=-v"
      end

      args.join(" ")
    end

    def run_linux_shell(key)
      override = backend_override_for(key)
      abort_with("Missing compose override file: #{override}") unless File.exist?(override)
      abort_with("Missing compose override file: #{LINUX_NO_PORTS_OVERRIDE}") unless File.exist?(LINUX_NO_PORTS_OVERRIDE)

      files = compose_files_for(key, linux: true)
      profiles = selected_profiles(key, linux: true)
      compose_scope = compose_scope_name(key: key, linux: true)
      compose_up(files: files, profiles: profiles, compose_scope: compose_scope)

      shell!(
        "#{compose_base(files, compose_scope: compose_scope)} #{profile_flags(profiles)} " \
        "run --rm --build #{app_service} bash"
      )
    end

    desc 'Run unit tests with AllegroGraph backend (docker deps, host Ruby)'
    task :ag do
      files = compose_files_for(:ag, linux: false)
      compose_scope = compose_scope_name(key: :ag, linux: false)
      run_host_tests(:ag)
    ensure
      Rake::Task['test'].reenable
      compose_down(files: files, profiles: selected_profiles(:ag, linux: false), compose_scope: compose_scope)
    end

    desc 'Run unit tests with AllegroGraph backend (docker deps, Linux container)'
    task 'ag:linux' do
      files = compose_files_for(:ag, linux: true)
      compose_scope = compose_scope_name(key: :ag, linux: true)
      begin
        run_linux_tests(:ag)
      ensure
        compose_down(files: files, profiles: selected_profiles(:ag, linux: true), compose_scope: compose_scope)
      end
    end

    desc 'Run unit tests with 4store backend (docker deps, host Ruby)'
    task :fs do
      files = compose_files_for(:fs, linux: false)
      compose_scope = compose_scope_name(key: :fs, linux: false)
      run_host_tests(:fs)
    ensure
      Rake::Task['test'].reenable
      compose_down(files: files, profiles: selected_profiles(:fs, linux: false), compose_scope: compose_scope)
    end

    desc 'Run unit tests with 4store backend (docker deps, Linux container)'
    task 'fs:linux' do
      files = compose_files_for(:fs, linux: true)
      compose_scope = compose_scope_name(key: :fs, linux: true)
      begin
        run_linux_tests(:fs)
      ensure
        compose_down(files: files, profiles: selected_profiles(:fs, linux: true), compose_scope: compose_scope)
      end
    end

    desc 'Run unit tests with Virtuoso backend (docker deps, host Ruby)'
    task :vo do
      files = compose_files_for(:vo, linux: false)
      compose_scope = compose_scope_name(key: :vo, linux: false)
      run_host_tests(:vo)
    ensure
      Rake::Task['test'].reenable
      compose_down(files: files, profiles: selected_profiles(:vo, linux: false), compose_scope: compose_scope)
    end

    desc 'Run unit tests with Virtuoso backend (docker deps, Linux container)'
    task 'vo:linux' do
      files = compose_files_for(:vo, linux: true)
      compose_scope = compose_scope_name(key: :vo, linux: true)
      begin
        run_linux_tests(:vo)
      ensure
        compose_down(files: files, profiles: selected_profiles(:vo, linux: true), compose_scope: compose_scope)
      end
    end

    desc 'Run unit tests with GraphDB backend (docker deps, host Ruby)'
    task :gd do
      files = compose_files_for(:gd, linux: false)
      compose_scope = compose_scope_name(key: :gd, linux: false)
      run_host_tests(:gd)
    ensure
      Rake::Task['test'].reenable
      compose_down(files: files, profiles: selected_profiles(:gd, linux: false), compose_scope: compose_scope)
    end

    desc 'Run unit tests with GraphDB backend (docker deps, Linux container)'
    task 'gd:linux' do
      files = compose_files_for(:gd, linux: true)
      compose_scope = compose_scope_name(key: :gd, linux: true)
      begin
        run_linux_tests(:gd)
      ensure
        compose_down(files: files, profiles: selected_profiles(:gd, linux: true), compose_scope: compose_scope)
      end
    end

    desc 'Run Linux-container unit tests against all backends in parallel'
    task 'all:linux' do
      backends = configured_backends.map(&:to_s)
      children = {}

      backends.each do |backend|
        cmd = [RbConfig.ruby, "-S", "bundle", "exec", "rake", "test:docker:#{backend}:linux"]
        puts "Starting [#{backend}]: #{cmd.join(' ')}"
        pid = spawn(*cmd, chdir: Dir.pwd, out: $stdout, err: $stderr)
        children[pid] = backend
      end

      failures = []
      children.each_key do |pid|
        _pid, status = Process.wait2(pid)
        backend = children[pid]
        if status.success?
          puts "Completed [#{backend}] successfully"
        else
          failures << backend
          puts "Failed [#{backend}] with exit status #{status.exitstatus}"
        end
      end

      abort_with("Parallel backend run failed: #{failures.join(', ')}") unless failures.empty?
    end

    desc 'Start a shell in the Linux test container (default backend: fs)'
    task :shell, [:backend] do |_t, args|
      key = (args[:backend] || DEFAULT_BACKEND).to_sym
      cfg!(key)
      files = compose_files_for(key, linux: true)
      compose_scope = compose_scope_name(key: key, linux: true)
      begin
        run_linux_shell(key)
      ensure
        compose_down(files: files, profiles: selected_profiles(key, linux: true), compose_scope: compose_scope)
      end
    end

    desc 'Start backend services for development (default backend: fs)'
    task :up, [:backend] do |_t, args|
      key = (args[:backend] || DEFAULT_BACKEND).to_sym
      cfg!(key)
      compose_scope = compose_scope_name(key: key, linux: false)
      compose_up(
        files: compose_files_for(key, linux: false),
        profiles: selected_profiles(key, linux: false),
        compose_scope: compose_scope
      )
    end

    desc 'Start all backend services (ag, fs, vo, gd) and dependency services'
    task 'up:all' do
      compose_up(
        files: compose_files_for(nil, linux: false),
        profiles: all_backend_profiles(linux: false),
        compose_scope: compose_scope_name(key: :all, linux: false)
      )
    end

    desc 'Stop backend services for development (optional arg: backend)'
    task :down, [:backend] do |_t, args|
      if args[:backend]
        if args[:backend].to_s == "all"
          compose_down(files: compose_files_for(nil, linux: false), profiles: all_backend_profiles(linux: false),
                       compose_scope: compose_scope_name(key: :all, linux: false))
        else
          key = args[:backend].to_sym
          cfg!(key)
          compose_down(files: compose_files_for(key, linux: false), profiles: selected_profiles(key, linux: false),
                       compose_scope: compose_scope_name(key: key, linux: false))
          compose_down(files: compose_files_for(key, linux: true), profiles: selected_profiles(key, linux: true),
                       compose_scope: compose_scope_name(key: key, linux: true))
        end
      else
        configured_backends.each do |key|
          compose_down(files: compose_files_for(key, linux: false), profiles: selected_profiles(key, linux: false),
                       compose_scope: compose_scope_name(key: key, linux: false))
          compose_down(files: compose_files_for(key, linux: true), profiles: selected_profiles(key, linux: true),
                       compose_scope: compose_scope_name(key: key, linux: true))
        end
      end
    end
  end
end
