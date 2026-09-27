# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe AmiPublish::StepRunner do
  # 呼ばれた順を記録するステップ。ログのステップ名に使われるよう、クラス名を付けておく。
  def recording_step(name, calls, error: nil)
    step_class = Class.new do
      define_method(:call) do |_context|
        calls << name
        raise error if error
      end
    end
    stub_const("AmiPublish::Steps::#{name}", step_class)
    step_class.new
  end

  it "ステップを順番に実行する" do
    calls = []
    steps = [recording_step("First", calls), recording_step("Second", calls)]

    described_class.new(steps: steps, logger: logger).run(context)

    expect(calls).to eq(%w[First Second])
    expect(log_events).to eq(%w[step_started step_finished step_started step_finished])
  end

  it "失敗したステップで止まり、以降のステップは実行しない" do
    calls = []
    steps = [recording_step("First", calls, error: AmiPublish::StepFailedError.new("失敗")),
             recording_step("Second", calls)]

    expect { described_class.new(steps: steps, logger: logger).run(context) }
      .to raise_error(AmiPublish::StepFailedError)
    expect(calls).to eq(%w[First])
    expect(log_events).to eq(%w[step_started step_failed])
  end
end
