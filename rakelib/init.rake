require "ontoportal/testkit/init_tasks"

namespace :test do
  namespace :testkit do
    runner = Ontoportal::Testkit::InitTasks.new

    desc "Initialize testkit files in the current component (args: force)"
    task :init, [:force] do |_t, args|
      runner.run(force_arg: args[:force])
    end
  end
end
