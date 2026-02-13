require "fileutils"

namespace :test do
  namespace :testkit do
    namespace :docker do
      desc "Build shared testkit base image (args: ruby_version,distro,tag,push)"
      task :build_base, [:ruby_version, :distro, :tag, :push] do |_t, args|
        ruby_version = args[:ruby_version] || ENV["RUBY_VERSION"] || "3.2"
        distro = args[:distro] || ENV["DISTRO"] || "bullseye"
        default_tag = "ontoportal/testkit-base:ruby#{ruby_version}-#{distro}"
        tag = args[:tag] || ENV["TESTKIT_BASE_TAG"] || default_tag
        push = (args[:push] || ENV["TESTKIT_BASE_PUSH"] || "false") == "true"
        platforms = "linux/amd64,linux/arm64/v8"
        output = if push
                   "--push"
                 else
                   archive = "tmp/testkit-base-ruby#{ruby_version}-#{distro}.oci.tar"
                   FileUtils.mkdir_p("tmp")
                   "--output type=oci,dest=#{archive}"
                 end

        cmd = [
          "docker buildx build",
          "--platform #{platforms}",
          "-f docker/base/Dockerfile",
          "--build-arg RUBY_VERSION=#{ruby_version}",
          "--build-arg DISTRO=#{distro}",
          "-t #{tag}",
          output,
          "."
        ].join(" ")

        puts "Building base image: #{tag} (platforms: #{platforms})"
        system(cmd) || abort("Command failed: #{cmd}")
      end
    end
  end
end
