require 'openssl'

# 動いている構成（Ruby、Rails、OpenSSL、接続元の IP）を返す
class HealthController < ApplicationController
  def show
    render plain: [
      "ruby: #{RUBY_VERSION}",
      "rails: #{Rails.version}",
      "openssl: #{OpenSSL::OPENSSL_LIBRARY_VERSION}",
      "remote_addr: #{request.env['REMOTE_ADDR']}",
      ''
    ].join("\n")
  end
end
