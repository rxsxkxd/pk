# frozen_string_literal: true

# 棚卸しツールの Ruby CLI 版で共通に使う部分。aws コマンドを子プロセスとして呼ぶ。標準ライブラリだけで動く。
#
# 正本は docs/seq/_common/ruby/cli/inventory_common.rb。各ツールにあるのは sync-common.sh で写したものなので、直接編集しない。
# AWS CLI の JSON 出力をそのまま（キーは API の名前の文字列）扱う。パラメータも API の名前のまま --cli-input-json で渡す。
#
# ツール側の service.rb（module Service）で定義するもの:
#   TOOL              使い方の表示に使うコマンド名
#   SNAPSHOT_OPTIONS  一覧取得（snapshot）のオプション { "--名前" => "説明" }。どれも繰り返し指定できる文字列
#   snapshot(ctx, opts)  一覧取得。レコードの配列を返す。opts はオプション名（先頭の -- を除き - を _ にしたもの）→ 値の配列
#   DETAIL_KINDS      詳細取得（detail）の種類 → [当てはまるレコード種別の配列, メソッド名]。メソッドは (ctx, record) を受ける

require "json"
require "open3"
require "optparse"
require "time"

module InventoryCommon
  # boto3 / SDK と CLI でサービス名が違うもの
  CLI_SERVICE_NAMES = { "s3" => "s3api" }.freeze
  ERROR_RE = /\((?<code>[^)]+)\) when calling the (?<operation>[A-Za-z0-9]+) operation(?: \(reached max retries: \d+\))?: (?<message>.*)/m
  ISO_RE = /\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})\z/

  class AwsError < StandardError
    attr_reader :operation, :code

    def initialize(operation, code, message)
      super(message)
      @operation = operation
      @code = code
    end
  end

  class Aws
    attr_reader :region

    def initialize
      # 混み合っているときは CLI が自分で送る速さを落とす
      @env = { "AWS_RETRY_MODE" => ENV.fetch("AWS_RETRY_MODE", "adaptive"), "AWS_PAGER" => "" }
      @region = ENV["AWS_REGION"] || ENV["AWS_DEFAULT_REGION"] || configured_region
    end

    def call(service, operation, params = {}, region = nil, paginate: true)
      cmd = ["aws", CLI_SERVICE_NAMES.fetch(service, service), operation.tr("_", "-"),
             "--cli-input-json", JSON.generate(params), "--output", "json"]
      cmd += ["--region", region] if region
      cmd << "--no-paginate" unless paginate
      out, err, status = Open3.capture3(@env, *cmd, stdin_data: "")
      unless status.success?
        m = ERROR_RE.match(err)
        raise AwsError.new(m[:operation], m[:code], m[:message].strip) if m

        raise AwsError.new(operation.split("_").map(&:capitalize).join, "Unknown", err.strip)
      end
      out.strip.empty? ? {} : JSON.parse(out)
    end

    private

    def configured_region
      out, _err, _status = Open3.capture3(@env, "aws", "configure", "get", "region", stdin_data: "")
      out.strip.empty? ? nil : out.strip
    end
  end

  # 一覧取得・詳細取得の間で持ち回る状態
  class Context
    attr_accessor :common
    attr_reader :aws

    def initialize(aws, interval = 0)
      @aws = aws
      @interval = interval
      @cache = {}
      @common = {}
    end

    # AWS の API を呼ぶ。詳細取得では 1 回ごとに間隔を空ける。paginate: false なら最初のページだけを取る
    def call(service, operation, params = {}, region = nil, paginate: true)
      sleep @interval if @interval.positive?
      @aws.call(service, operation, params, region, paginate: paginate)
    end

    # 「設定が無い」ことをエラーで返す API 用。codes のエラーコードなら nil を返す
    def call_or_nil(codes, service, operation, params = {}, region = nil)
      call(service, operation, params, region)
    rescue AwsError => e
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

  # タグの配列（Key/Value または key/value）をオブジェクトにする
  def tags_object(tags)
    (tags || []).to_h { |t| [t.key?("Key") ? t["Key"] : t["key"], t.key?("Value") ? t["Value"] : t["value"]] }
  end

  def error_entry(error) = { "operation" => error.operation, "code" => error.code, "message" => error.message }

  def write(record) = $stdout.puts(JSON.generate(record))

  def main(service, argv)
    command = argv.shift
    aws = Aws.new
    case command
    when "snapshot" then run_snapshot(service, aws, argv)
    when "detail" then run_detail(service, aws, argv)
    else abort usage(service)
    end
  rescue AwsError => e
    abort "#{e.operation}: #{e.code}: #{e.message}"
  end

  def usage(service)
    <<~USAGE
      usage:
        #{service::TOOL} snapshot #{service::SNAPSHOT_OPTIONS.keys.map { |o| "[#{o} VALUE]..." }.join(' ')}
        #{service::TOOL} detail --with KIND[,KIND...] [--interval SEC] [--max N] < records.jsonl

        KIND: #{service::DETAIL_KINDS.keys.join(', ').then { |s| s.empty? ? '（なし）' : s }}
    USAGE
  end

  def run_snapshot(service, aws, argv)
    opts = service::SNAPSHOT_OPTIONS.keys.to_h { |o| [o.delete_prefix("--").tr("-", "_"), []] }
    OptionParser.new(usage(service)) do |parser|
      service::SNAPSHOT_OPTIONS.each do |name, help|
        parser.on("#{name} VALUE", help) { |v| opts[name.delete_prefix("--").tr("-", "_")] << v }
      end
    end.parse!(argv)

    ctx = Context.new(aws)
    account = aws.call("sts", "get_caller_identity")["Account"]
    ctx.common = { "account_id" => account, "region" => aws.region, "collected_at" => now_iso }
    service.snapshot(ctx, opts).each { |record| write(record) }
  end

  def run_detail(service, aws, argv)
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

    ctx = Context.new(aws, interval)
    records.each do |record|
      details = {}
      errors = []
      kinds.each do |kind|
        types, method_name = service::DETAIL_KINDS.fetch(kind)
        next unless types.include?(record["record_type"])

        begin
          details[kind] = service.public_send(method_name, ctx, record)
        rescue AwsError => e
          details[kind] = nil
          errors << error_entry(e)
        end
      end
      write(record.merge("details_collected_at" => now_iso, "details" => details,
                         "errors" => (record["errors"] || []) + errors))
    end
  end
end
