#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 4: 検証に必要な AWS の状態を集め、判定器（generate_green_verification_report
# --input-dir）が読むファイル一式を書き出す。**収集だけを行う。判定はしない。**
# ロジックは lib/green_state.rb にある。
#
# 同じ内容の Go 版（scripts/collect_green_state/）を残してある。
# **どちらを変えても、もう一方へ同じ変更を入れる**（tests/green_tools_go_rb_parity_test.sh）。
#
# 標準出力には、呼び出し側（verify_green.sh）が続きで使う値を KEY=値 の行で出す。
# 呼び出し側は変数へ受けてから eval する（eval "$(...)" と書くと失敗をすり抜けるため）。
#
#   DEPLOYMENT_ID      引き当てた Blue/Green Deployment の識別子
#   GREEN_INSTANCE_ID  Green の DB インスタンス識別子
#   GREEN_ENDPOINT     Green のエンドポイント（実効値収集が接続する先）
require 'optparse'

require_relative 'lib/green_state'

# Go の time.ParseDuration の書式（10m / 600s / 1h30m など）を秒へ直す。
def parse_duration(text)
  units = { 'h' => 3600, 'm' => 60, 's' => 1, 'ms' => 0.001 }
  raise ArgumentError, text unless text.match?(/\A(?:\d+(?:\.\d+)?(?:ms|h|m|s))+\z/)

  text.scan(/(\d+(?:\.\d+)?)(ms|h|m|s)/).sum { |amount, unit| amount.to_f * units.fetch(unit) }
end

options = { region: '', profile: '', source_id: '', target_parameter_group: '', output_dir: '',
            replica_lag_window: '10m' }
parser = OptionParser.new do |opts|
  opts.banner = 'Usage: collect_green_state.rb --region REGION --source-id ID ' \
                '--target-parameter-group NAME --output-dir DIR [--profile PROFILE] [--replica-lag-window 10m]'
  opts.on('--region REGION', 'AWS リージョン（必須）') { |v| options[:region] = v }
  opts.on('--profile PROFILE', 'AWS CLI の named profile（省略可）') { |v| options[:profile] = v }
  opts.on('--source-id ID', '移行元の DB インスタンス識別子（必須）') { |v| options[:source_id] = v }
  opts.on('--target-parameter-group NAME', 'Green に関連付けた 8.4 パラメータグループ名（必須）') { |v| options[:target_parameter_group] = v }
  opts.on('--output-dir DIR', '収集結果の出力先ディレクトリ（必須）') { |v| options[:output_dir] = v }
  opts.on('--replica-lag-window DURATION', 'レプリカ遅延を見る期間（default: 10m）') { |v| options[:replica_lag_window] = v }
  opts.on('-h', '--help') { puts opts; exit 0 }
end
begin
  parser.parse!
rescue OptionParser::ParseError => e
  warn e.message
  warn parser.banner
  exit 2
end

%i[region source_id target_parameter_group output_dir].each do |key|
  next unless options[key].empty?

  warn "--#{key.to_s.tr('_', '-')} is required."
  exit 2
end
begin
  window = parse_duration(options[:replica_lag_window])
rescue ArgumentError
  warn "invalid value \"#{options[:replica_lag_window]}\" for flag -replica-lag-window"
  exit 2
end

begin
  result = GreenState.collect(region: options[:region], profile: options[:profile],
                              source_id: options[:source_id],
                              target_parameter_group: options[:target_parameter_group],
                              output_dir: options[:output_dir], replica_lag_window: window)
rescue GreenState::Error => e
  warn e.message
  exit 1
end

# eval されるので、値はシェル向けに単一引用符で囲む。値に含まれる ' は '\'' に置き換える。
{
  'DEPLOYMENT_ID' => result.deployment_id,
  'GREEN_INSTANCE_ID' => result.green_instance_id,
  'GREEN_ENDPOINT' => result.green_endpoint
}.each { |name, value| puts "#{name}='#{value.gsub("'") { %q('\'') }}'" }
