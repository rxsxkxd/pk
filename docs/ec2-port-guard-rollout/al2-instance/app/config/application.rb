require File.expand_path('../boot', __FILE__)

require 'action_controller/railtie'

Bundler.require(*Rails.groups)

module App
  class Application < Rails::Application
    # 試すためのアプリなので、秘密の値は固定にする（本物のアプリでは環境ごとに設定する）
    config.secret_key_base = ENV.fetch('SECRET_KEY_BASE', 'port-guard-rollout-al2-instance-only-for-local-testing')
  end
end
