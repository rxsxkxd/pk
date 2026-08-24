# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe AmiPublish::ProgressLogger do
  it "最初の 1 回と、その後は間隔ごとにだけ進捗を出す" do
    now = 0
    progress = described_class.new(logger: logger, description: "AMI の作成", interval_seconds: 60,
                                   clock: -> { now })

    [0, 30, 59, 60, 90, 125].each do |seconds|
      now = seconds
      progress.report { { state: "pending" } }
    end

    expect(waiting_logs.map { |record| record["elapsed_seconds"] }).to eq([0, 60, 125])
    expect(waiting_logs.first).to include("description" => "AMI の作成", "state" => "pending")
  end

  it "ログを出さないときは、項目のブロックを評価しない（追加の API 呼び出しを避ける）" do
    now = 0
    evaluated = 0
    progress = described_class.new(logger: logger, description: "x", interval_seconds: 60, clock: -> { now })

    3.times do
      progress.report { evaluated += 1 and {} }
    end

    expect(evaluated).to eq(1)
  end
end
