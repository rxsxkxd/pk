# frozen_string_literal: true

module AmiPublish
  # JSON 形式のログを 1 行ずつ出力する。CodeBuild のログ（CloudWatch Logs）で検索・集計しやすくするため。
  class StructuredLogger
    def initialize(output: $stdout, clock: -> { Time.now.utc })
      @output = output
      @clock = clock
    end

    def info(event, **fields)
      write("info", event, fields)
    end

    def error(event, **fields)
      write("error", event, fields)
    end

    private

    def write(level, event, fields)
      record = { time: @clock.call.iso8601(3), level: level, event: event }.merge(fields)
      @output.puts(JSON.generate(record))
      @output.flush
    end
  end
end
