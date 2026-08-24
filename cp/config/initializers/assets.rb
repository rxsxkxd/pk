Rails.application.config.assets.version = "1.0"
Rails.application.config.assets.paths << Rails.root.join("app", "assets", "builds")
Rails.application.config.assets.precompile += %w[application.js]
