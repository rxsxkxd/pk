Capybara.server = :puma, { Silent: true }
Capybara.server_host = "0.0.0.0"
Capybara.server_port = 3001
Capybara.app_host = ENV.fetch("CAPYBARA_APP_HOST", "http://rails:3001")

Capybara.register_driver :remote_chrome do |app|
  options = Selenium::WebDriver::Options.chrome
  options.add_argument("--headless=new")
  options.add_argument("--no-sandbox")
  options.add_argument("--disable-dev-shm-usage")

  Capybara::Selenium::Driver.new(
    app,
    browser: :remote,
    url: ENV.fetch("SELENIUM_URL", "http://selenium:4444/wd/hub"),
    capabilities: options
  )
end

Capybara.javascript_driver = :remote_chrome
