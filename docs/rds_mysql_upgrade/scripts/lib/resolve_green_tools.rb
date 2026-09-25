#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Step 4 が使う Go バイナリの場所を決める。
#
#   collect_green_runtime_values       … Green DB の実効値収集（mysql クライアントの代替）
#   generate_green_verification_report … 突き合わせとレポートの組み立て
#
# 探す順は「呼び出し側の指定（環境変数）→ BuildReportTool の artifact → ソースツリー」。
#
# 2 つの使い方がある。
#
#   ruby scripts/lib/resolve_green_tools.rb
#     VerifyGreen（CI）用。2 本とも探し、**ビルドはしない。**VerifyGreen は Go も
#     外部ネットワークも持たない前提なので、見つからなければ理由と対処を出して終了コード 1。
#
#   ruby scripts/lib/resolve_green_tools.rb --build-missing <名前>...
#     verify_green.sh 用。指定した分だけ探し、見つからなければ **その場でビルドする**
#     （ローカル実行で環境変数を渡していない場合）。ビルド先はリポジトリの
#     .tools/green-report/（.gitignore 済み。GREEN_TOOLS_BUILD_DIR で変えられる）。
#     Go のビルドキャッシュが効くので毎回ビルドしても速い。
#
# 出力は `KEY='値'` の行で、呼び出し側が変数へ受けてから eval する
# （eval "$(...)" と 1 行で書くと失敗をすり抜ける）。診断メッセージは stderr へ出す。
#
# Ruby から使う場合は require_relative して GreenTools.resolve / resolve_or_build を呼ぶ。
require 'fileutils'
require 'shellwords'

module GreenTools
  class Error < StandardError; end

  # artifact とソースツリーのどちらでも、この相対パスに置かれる。
  TOOL_DIR = '.tools/green-report'
  REPOSITORY_ROOT = File.expand_path('../..', __dir__)

  TOOLS = [
    { variable: 'GREEN_RUNTIME_COLLECTOR', basename: 'collect_green_runtime_values',       label: 'runtime value collector' },
    { variable: 'GREEN_REPORT_GENERATOR',  basename: 'generate_green_verification_report', label: 'report generator' },
  ].freeze

  module_function

  def tool(basename)
    TOOLS.find { |entry| entry[:basename] == basename } or raise Error, "未知のツール: #{basename}"
  end

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

  # 見つかればパスを返す。見つからなければ nil（理由は出さない）。
  def resolve(tool)
    found = candidates(tool).find { |path, _| File.file?(path) }
    return nil if found.nil?

    warn "Using #{found[1]}."
    found[0]
  end

  # 見つからなければリポジトリの .tools/green-report/ へビルドしてそのパスを返す。
  def resolve_or_build(tool)
    resolve(tool) || build(tool)
  end

  def build(tool)
    unless system('command -v go >/dev/null 2>&1')
      raise Error, "#{tool[:label]} が見つからず、Go も無いのでビルドできない。" \
                   "#{tool[:variable]} でビルド済みバイナリを渡すこと。"
    end
    build_dir = ENV['GREEN_TOOLS_BUILD_DIR'].to_s
    build_dir = File.join(REPOSITORY_ROOT, TOOL_DIR) if build_dir.empty?
    output = File.join(build_dir, tool[:basename])
    FileUtils.mkdir_p(File.dirname(output))
    warn "Building the #{tool[:label]} locally: #{output}"
    unless system('go', '-C', REPOSITORY_ROOT, 'build', '-o', output, "./scripts/#{tool[:basename]}")
      raise Error, "#{tool[:label]} のビルドに失敗した。"
    end
    output
  end

  def absent(tool)
    warn "The #{tool[:label]} is absent. This project does not build it on purpose"
    warn '(it must run without reaching the network outside the VPC).'
    warn 'Run ci/codebuild/build-report-tool.yml and pass its artifact,'
    warn "or set #{tool[:variable]} to a prebuilt binary."
    warn '探した場所:'
    candidates(tool).each { |path, _| warn "  #{path}" }
  end
end

if $PROGRAM_NAME == __FILE__
  assignments = {}
  begin
    if ARGV.first == '--build-missing'
      names = ARGV.drop(1)
      abort 'Usage: resolve_green_tools.rb [--build-missing NAME...]' if names.empty?
      names.each do |name|
        tool = GreenTools.tool(name)
        assignments[tool[:variable]] = GreenTools.resolve_or_build(tool)
      end
    else
      missing = false
      GreenTools::TOOLS.each do |tool|
        path = GreenTools.resolve(tool)
        if path.nil?
          GreenTools.absent(tool)
          missing = true
          next
        end
        assignments[tool[:variable]] = path
      end
      exit 1 if missing
    end
  rescue GreenTools::Error => e
    warn e.message
    exit 1
  end
  assignments.each { |variable, path| puts "#{variable}=#{Shellwords.escape(path)}" }
end
