#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 4 が使うビルド済みバイナリ 3 本の場所を決める。**ビルドはしない。**
#
#   collect_green_state                … AWS の状態収集
#   collect_green_runtime_values       … Green DB の実効値収集（mysql クライアントの代替）
#   generate_green_verification_report … 突き合わせとレポートの組み立て
#
# VerifyGreen は Go も外部ネットワークも持たない前提なので、見つからなければ
# 理由と対処を出して終了コード 1 を返す。**その場でビルドして回復させない。**
#
# 出力は `KEY='値'` の行で、呼び出し側が eval して環境変数にする
# （scripts/lib/deployment_config.sh と同じ流儀）。診断メッセージは stderr へ出す。
# 標準出力には eval される行だけを載せる。
#
# 使い方:
#   vars=$(ruby scripts/lib/resolve_green_tools.rb) || exit 1
#   eval "$vars"
#   export GREEN_STATE_COLLECTOR GREEN_RUNTIME_COLLECTOR GREEN_REPORT_GENERATOR
require 'shellwords'

# artifact とソースツリーのどちらでも、この相対パスに置かれる。
TOOL_DIR = '.tools/green-report'

TOOLS = [
  { variable: 'GREEN_STATE_COLLECTOR',   basename: 'collect_green_state',                label: 'state collector' },
  { variable: 'GREEN_RUNTIME_COLLECTOR', basename: 'collect_green_runtime_values',       label: 'runtime value collector' },
  { variable: 'GREEN_REPORT_GENERATOR',  basename: 'generate_green_verification_report', label: 'report generator' },
].freeze

# 探す順に「どこから来たか」を添えて返す。呼び出し側の指定を最優先する。
def candidates(tool)
  given = ENV[tool[:variable]].to_s
  artifact = ENV['CODEBUILD_SRC_DIR_ReportToolOutput'].to_s
  source = ENV['CODEBUILD_SRC_DIR'].to_s
  list = []
  list << [given, "#{tool[:variable]} given by the caller"] unless given.empty?
  list << [File.join(artifact, TOOL_DIR, tool[:basename]), "the #{tool[:label]} from the BuildReportTool artifact"] unless artifact.empty?
  list << [File.join(source, TOOL_DIR, tool[:basename]), "the #{tool[:label]} found in the source tree"] unless source.empty?
  list
end

def absent(tool)
  warn "The #{tool[:label]} is absent. This project does not build it on purpose"
  warn '(it must run without reaching the network outside the VPC).'
  warn 'Run ci/codebuild/build-report-tool.yml and pass its artifact,'
  warn "or set #{tool[:variable]} to a prebuilt binary."
  warn '探した場所:'
  candidates(tool).each { |path, _| warn "  #{path}" }
end

resolved = {}
missing = false
TOOLS.each do |tool|
  found = candidates(tool).find { |path, _| File.file?(path) }
  if found.nil?
    absent(tool)
    missing = true
    next
  end
  path, origin = found
  warn "Using #{origin}."
  resolved[tool[:variable]] = path
end
exit 1 if missing

resolved.each { |variable, path| puts "#{variable}=#{Shellwords.escape(path)}" }
