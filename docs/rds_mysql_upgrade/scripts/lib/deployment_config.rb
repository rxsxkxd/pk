# frozen_string_literal: true
#
# 実行設定 YAML（config/blue-green/<環境>.deployment.yml）の読み取り（Ruby 版）。
#
# シェル版（deployment_config.sh）は Ruby で YAML→JSON にしてから jq で取り出すが、
# 呼び出し元が Ruby なら **psych で直接読めるので jq を経由しない。**
# 必須・任意の意味づけと、未定義のときのメッセージはシェル版と揃えてある
# （`<パス> が未定義である` / `services.<名前> が未定義である`）。
#
# 使い方:
#   require_relative 'lib/deployment_config'
#   config = DeploymentConfig.load(path)
#   region = config.required('aws_region')
#   svc    = config.service('example-service')
#   id     = svc.required('source_db_instance_identifier')
require 'yaml'

class DeploymentConfig
  # 設定の読み取りに失敗したときに投げる。呼び出し側は rescue して exit する。
  class Error < StandardError; end

  def self.load(path)
    document = YAML.safe_load(File.read(path))
    raise Error, "#{path}: YAML がマッピングではない" unless document.is_a?(Hash)
    new(document, '')
  rescue Errno::ENOENT, Errno::EACCES => e
    raise Error, "#{path}: YAML を読み込めなかった: #{e.message}"
  rescue Psych::SyntaxError => e
    raise Error, "#{path}: YAML を解析できなかった: #{e.message}"
  end

  def initialize(document, prefix)
    @document = document
    @prefix = prefix
  end

  # 必須項目。空・未定義なら文脈付きで落とす（シェル版の required と同じ）。
  def required(key)
    value = @document[key]
    raise Error, "#{qualify(key)} が未定義である" if value.nil? || value.to_s.empty?
    value.to_s
  end

  # 任意項目。未定義なら既定値を使う（シェル版の optional と同じ）。
  def optional(key, fallback = '')
    value = @document[key]
    return fallback if value.nil? || value.to_s.empty?
    value.to_s
  end

  # services.<名前> を取り出す（シェル版の service と同じ）。
  def service(name)
    services = @document['services']
    entry = services.is_a?(Hash) ? services[name] : nil
    raise Error, "services.#{name} が未定義である" unless entry.is_a?(Hash)
    DeploymentConfig.new(entry, "services.#{name}")
  end

  private

  def qualify(key)
    @prefix.empty? ? key : "#{@prefix}.#{key}"
  end
end
