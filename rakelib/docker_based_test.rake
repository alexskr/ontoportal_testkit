# Docker compose driven unit test orchestration
#
# Notes:
# - Backend names match compose profile names (ag, fs, vo, gd).
# - Hostnames are NOT set for host Ruby runs; config defaults to localhost.
# - Linux container env is provided via compose override files in dev/compose/linux.
namespace :test do
  namespace :docker do
    BASE_COMPOSE = 'docker-compose.yml'
    LINUX_OVERRIDE_DIR = 'dev/compose/linux'
    LINUX_NO_PORTS_OVERRIDE = "#{LINUX_OVERRIDE_DIR}/no-ports.yml"
    TIMEOUT = (ENV['OP_TEST_DOCKER_TIMEOUT'] || '600').to_i
    DEFAULT_BACKEND = (ENV['OP_TEST_DOCKER_BACKEND'] || 'fs').to_sym

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
    }.freeze

    def abort_with(msg)
      warn(msg)
      exit(1)
    end

    def shell!(cmd)
      system(cmd) || abort_with("Command failed: #{cmd}")
    end

    def cfg!(key)
      cfg = BACKENDS[key]
      abort_with("Unknown backend key: #{key}. Supported: #{BACKENDS.keys.join(', ')}") unless cfg
      cfg
    end

    def project_config
      @project_config ||= Ontoportal::Testkit::ProjectConfig.new
    end

    def compose_files(*files)
      files.flatten.map { |f| "-f #{f}" }.join(' ')
    end

    def linux_override_for(key)
      "#{LINUX_OVERRIDE_DIR}/#{key}.yml"
    end

    def optional_override_for(service_name)
      "#{LINUX_OVERRIDE_DIR}/#{service_name}.yml"
    end

    def optional_services
      env = ENV['OP_TEST_DOCKER_OPTIONAL_SERVICES']
      return env.split(',').map(&:strip).reject(&:empty?) if env && !env.strip.empty?

      project_config.optional_services.map(&:to_s)
    end

    def optional_override_files
      optional_services.map do |service_name|
        override = optional_override_for(service_name)
        abort_with("Missing optional service override file: #{override}") unless File.exist?(override)
        override
      end
    end

    def compose_files_for(key = nil, linux: false)
      files = [BASE_COMPOSE]
      files << linux_override_for(key) if linux && key
      files.concat(optional_override_files)
      files << LINUX_NO_PORTS_OVERRIDE if linux
      files
    end

    def app_service
      project_config.app_service.to_s
    end

    def compose_up(key, files:)
      shell!("docker compose #{compose_files(files)} --profile #{key} up -d --wait --wait-timeout #{TIMEOUT}")
    end

    def compose_down(files:)
      return puts('OP_KEEP_CONTAINERS=1 set, skipping docker compose down') if ENV['OP_KEEP_CONTAINERS'] == '1'
      shell!("docker compose #{compose_files(files)} down")
    end

    def apply_host_env(key)
      cfg!(key)[:host_env].each { |k, v| ENV[k] = v }
    end

    def run_host_tests(key)
      apply_host_env(key)
      files = compose_files_for(key, linux: false)

      compose_up(key, files: files)
      Rake::Task['test'].invoke
    end

    def run_linux_tests(key)
      override = linux_override_for(key)
      abort_with("Missing compose override file: #{override}") unless File.exist?(override)
      abort_with("Missing compose override file: #{LINUX_NO_PORTS_OVERRIDE}") unless File.exist?(LINUX_NO_PORTS_OVERRIDE)

      files = compose_files_for(key, linux: true)
      compose_up(key, files: files)

      shell!(
        "docker compose #{compose_files(files)} --profile linux --profile #{key} " \
        "run --rm --build #{app_service} bundle exec rake test TESTOPTS=\"-v\""
      )
    end

    def run_linux_shell(key)
      override = linux_override_for(key)
      abort_with("Missing compose override file: #{override}") unless File.exist?(override)
      abort_with("Missing compose override file: #{LINUX_NO_PORTS_OVERRIDE}") unless File.exist?(LINUX_NO_PORTS_OVERRIDE)

      files = compose_files_for(key, linux: true)
      compose_up(key, files: files)

      shell!(
        "docker compose #{compose_files(files)} --profile linux --profile #{key} " \
        "run --rm --build #{app_service} bash"
      )
    end

    desc 'Run unit tests with AllegroGraph backend (docker deps, host Ruby)'
    task :ag do
      files = compose_files_for(:ag, linux: false)
      run_host_tests(:ag)
    ensure
      Rake::Task['test'].reenable
      compose_down(files: files)
    end

    desc 'Run unit tests with AllegroGraph backend (docker deps, Linux container)'
    task 'ag:linux' do
      files = compose_files_for(:ag, linux: true)
      begin
        run_linux_tests(:ag)
      ensure
        compose_down(files: files)
      end
    end

    desc 'Run unit tests with 4store backend (docker deps, host Ruby)'
    task :fs do
      files = compose_files_for(:fs, linux: false)
      run_host_tests(:fs)
    ensure
      Rake::Task['test'].reenable
      compose_down(files: files)
    end

    desc 'Run unit tests with 4store backend (docker deps, Linux container)'
    task 'fs:linux' do
      files = compose_files_for(:fs, linux: true)
      begin
        run_linux_tests(:fs)
      ensure
        compose_down(files: files)
      end
    end

    desc 'Run unit tests with Virtuoso backend (docker deps, host Ruby)'
    task :vo do
      files = compose_files_for(:vo, linux: false)
      run_host_tests(:vo)
    ensure
      Rake::Task['test'].reenable
      compose_down(files: files)
    end

    desc 'Run unit tests with Virtuoso backend (docker deps, Linux container)'
    task 'vo:linux' do
      files = compose_files_for(:vo, linux: true)
      begin
        run_linux_tests(:vo)
      ensure
        compose_down(files: files)
      end
    end

    desc 'Run unit tests with GraphDB backend (docker deps, host Ruby)'
    task :gd do
      files = compose_files_for(:gd, linux: false)
      run_host_tests(:gd)
    ensure
      Rake::Task['test'].reenable
      compose_down(files: files)
    end

    desc 'Run unit tests with GraphDB backend (docker deps, Linux container)'
    task 'gd:linux' do
      files = compose_files_for(:gd, linux: true)
      begin
        run_linux_tests(:gd)
      ensure
        compose_down(files: files)
      end
    end

    desc 'Start a shell in the Linux test container (default backend: fs)'
    task :shell, [:backend] do |_t, args|
      key = (args[:backend] || DEFAULT_BACKEND).to_sym
      cfg!(key)
      files = compose_files_for(key, linux: true)
      begin
        run_linux_shell(key)
      ensure
        compose_down(files: files)
      end
    end

    desc 'Start backend services for development (default backend: fs)'
    task :up, [:backend] do |_t, args|
      key = (args[:backend] || DEFAULT_BACKEND).to_sym
      cfg!(key)
      compose_up(key, files: compose_files_for(key, linux: false))
    end

    desc 'Stop backend services for development'
    task :down do
      compose_down(files: compose_files_for(nil, linux: false))
    end
  end
end
