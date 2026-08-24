require_relative "boot"

require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "sprockets/railtie"

module ReactCapybaraApp
  class Application < Rails::Application
    config.load_defaults 7.2
    config.generators.system_tests = nil
  end
end
