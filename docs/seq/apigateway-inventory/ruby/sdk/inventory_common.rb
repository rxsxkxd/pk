# frozen_string_literal: true

# 棚卸しツールの Ruby SDK 版で共通に使う部分。AWS SDK for Ruby を使う。
#
# 正本は docs/seq/_common/ruby/sdk/inventory_common.rb。各ツールにあるのは sync-common.sh で写したものなので、直接編集しない。
#
# ツール側の service.rb（module Service）で定義するもの:
#   TOOL              使い方の表示に使うコマンド名
#   SNAPSHOT_OPTIONS  一覧取得（snapshot）のオプション { "--名前" => "説明" }。どれも繰り返し指定できる文字列
#   snapshot(ctx, opts)  一覧取得。レコードの配列を返す。opts はオプション名（先頭の -- を除き - を _ にしたもの）→ 値の配列
#   DETAIL_KINDS      詳細取得（detail）の種類 → [当てはまるレコード種別の配列, メソッド名]。メソッドは (ctx, record) を受ける
#
# SDK の呼び出しは ctx.client(:EC2) などで得たクライアントで行い、詳細取得では ctx.pace { ... } で囲む。

require "json"
require "optparse"
require "time"
require "aws-sdk-core"

module InventoryCommon
  ISO_RE = /\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})\z/
  # 混み合っているときは SDK が自分で送る速さを落とす
  CLIENT_OPTIONS = { retry_mode: "adaptive" }.freeze

  # 一覧取得・詳細取得の間で持ち回る状態
  class Context
    attr_accessor :common
    attr_reader :region

    def initialize(interval = 0)
      @interval = interval
      @cache = {}
      @clients = {}
      @common = {}
      @region = client(:STS).config.region
    end

    # サービスのクライアント（例: client(:EC2)、client(:WAFV2, "us-east-1")）
    def client(name, region = nil)
      @clients[[name, region]] ||= begin
        options = region ? CLIENT_OPTIONS.merge(region: region) : CLIENT_OPTIONS
        ::Aws.const_get(name)::Client.new(**options)
      end
    end

    # 詳細取得では、呼び出しの前に間隔を空ける
    def pace
      sleep @interval if @interval.positive?
      yield
    end

    # 「設定が無い」ことをエラーで返す API 用。codes のエラーコードなら nil を返す
    def pace_or_nil(codes, &block)
      pace(&block)
    rescue ::Aws::Errors::ServiceError => e
      raise unless codes.include?(e.code)

      nil
    end

    # 同じキーの結果は 1 回の実行で 1 回だけ取る
    def cached(key)
      @cache.key?(key) ? @cache[key] : (@cache[key] = yield)
    end

    # 共通の項目を付けてレコードにする。fields に region があれば、そちらを使う
    def record(record_type, fields, errors = [])
      { "record_type" => record_type, **@common, **fields, "errors" => errors }
    end
  end

  module_function

  # 日時を UTC の秒単位（YYYY-MM-DDTHH:MM:SSZ）にそろえる。Time、ISO 8601 の文字列、エポック秒を受け付ける
  def utc_iso(value)
    case value
    when nil then nil
    when Time then value.getutc.strftime("%Y-%m-%dT%H:%M:%SZ")
    when Numeric then Time.at(value.to_i).getutc.strftime("%Y-%m-%dT%H:%M:%SZ")
    else
      m = ISO_RE.match(value.to_s) or return value
      tz = m[3]
      offset = tz == "Z" ? 0 : (tz.start_with?("-") ? -1 : 1) * ((tz[1, 2].to_i * 3600) + (tz[-2, 2].to_i * 60))
      utc_iso(Time.utc(*m[1].scan(/\d+/).map(&:to_i)).to_i - offset)
    end
  end

  # エポック秒の文字列（SQS などの属性）を UTC にする
  def epoch_iso(value) = value.nil? ? nil : utc_iso(value.to_f.to_i)

  def now_iso = utc_iso(Time.now)

  # SDK のタグの配列（key/value のどちらの書き方でも）をオブジェクトにする
  def tags_object(tags)
    (tags || []).to_h { |t| [t.key, t.value] }
  end

  # SDK のエラーを、CLI 版と同じ { operation, code, message } にする
  def error_entry(error)
    operation = error.context&.operation&.name || error.context&.operation_name.to_s
    { "operation" => operation, "code" => error.code, "message" => error.message }
  end

  def write(record) = $stdout.puts(JSON.generate(record))

  def main(service, argv)
    case argv.shift
    when "snapshot" then run_snapshot(service, argv)
    when "detail" then run_detail(service, argv)
    else abort usage(service)
    end
  rescue ::Aws::Errors::ServiceError => e
    entry = error_entry(e)
    abort "#{entry['operation']}: #{entry['code']}: #{entry['message']}"
  end

  def usage(service)
    <<~USAGE
      usage:
        #{service::TOOL} snapshot #{service::SNAPSHOT_OPTIONS.keys.map { |o| "[#{o} VALUE]..." }.join(' ')}
        #{service::TOOL} detail --with KIND[,KIND...] [--interval SEC] [--max N] < records.jsonl

        KIND: #{service::DETAIL_KINDS.keys.join(', ').then { |s| s.empty? ? '（なし）' : s }}
    USAGE
  end

  def run_snapshot(service, argv)
    opts = service::SNAPSHOT_OPTIONS.keys.to_h { |o| [o.delete_prefix("--").tr("-", "_"), []] }
    OptionParser.new(usage(service)) do |parser|
      service::SNAPSHOT_OPTIONS.each do |name, help|
        parser.on("#{name} VALUE", help) { |v| opts[name.delete_prefix("--").tr("-", "_")] << v }
      end
    end.parse!(argv)

    ctx = Context.new
    account = ctx.client(:STS).get_caller_identity.account
    ctx.common = { "account_id" => account, "region" => ctx.region, "collected_at" => now_iso }
    service.snapshot(ctx, opts).each { |record| write(record) }
  end

  def run_detail(service, argv)
    kinds = []
    interval = 0.2
    max = 100
    OptionParser.new(usage(service)) do |parser|
      parser.on("--with KINDS") { |v| kinds = v.split(",") }
      parser.on("--interval SEC", Float) { |v| interval = v }
      parser.on("--max N", Integer) { |v| max = v }
    end.parse!(argv)
    abort usage(service) if kinds.empty?
    (kinds - service::DETAIL_KINDS.keys).each { |k| abort "不明な詳細の種類: #{k}" }

    # 件数が多すぎるときは、絞り込み忘れとみなして止める
    records = $stdin.each_line.reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
    if records.size > max
      abort "入力が #{records.size} 件あり、上限（--max #{max}）を超えています。jq で絞り込むか、--max を上げてください"
    end

    ctx = Context.new(interval)
    records.each do |record|
      details = {}
      errors = []
      kinds.each do |kind|
        types, method_name = service::DETAIL_KINDS.fetch(kind)
        next unless types.include?(record["record_type"])

        begin
          details[kind] = service.public_send(method_name, ctx, record)
        rescue ::Aws::Errors::ServiceError => e
          details[kind] = nil
          errors << error_entry(e)
        end
      end
      write(record.merge("details_collected_at" => now_iso, "details" => details,
                         "errors" => (record["errors"] || []) + errors))
    end
  end
end
