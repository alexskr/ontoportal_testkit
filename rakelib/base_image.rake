namespace :test do
  namespace :testkit do
    namespace :docker do
      desc "Build shared testkit base image (args: ruby_version,distro,tag)"
      task :build_base, [:ruby_version, :distro, :tag] do |_t, args|
        ruby_version = args[:ruby_version] || ENV["RUBY_VERSION"] || "3.2"
        distro = args[:distro] || ENV["DISTRO"] || "bullseye"
        default_tag = "ontoportal/testkit-base:ruby#{ruby_version}-#{distro}"
        tag = args[:tag] || ENV["TESTKIT_BASE_TAG"] || default_tag

        cmd = [
          "docker build",
          "-f docker/base/Dockerfile",
          "--build-arg RUBY_VERSION=#{ruby_version}",
          "--build-arg DISTRO=#{distro}",
          "-t #{tag}",
          "."
        ].join(" ")

        puts "Building base image: #{tag}"
        system(cmd) || abort("Command failed: #{cmd}")
      end
    end
  end
end
