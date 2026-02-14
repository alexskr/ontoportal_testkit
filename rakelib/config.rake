namespace :test do
  namespace :testkit do
    desc "Show loaded testkit component config"
    task :config do
      cfg = Ontoportal::Testkit::ComponentConfig.new
      puts "component_name: #{cfg.component_name}"
      puts "app_service: #{cfg.app_service}"
      puts "backends: #{cfg.backends.join(", ")}"
      puts "dependency_services: #{cfg.dependency_services.join(", ")}"
    end
  end
end
