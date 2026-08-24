# frozen_string_literal: true

module AmiPublish
  # 時間のかかる待機処理の進捗をログに出す。
  # 確認のたびに report を呼んでよい。実際にログを出すのは、最初の 1 回と、その後は interval_seconds ごと。
  # ログの項目はブロックで渡す（ログを出すときだけ評価するため、追加の API 呼び出しを伴う項目も渡せる）。
  #
  #   {"event":"waiting","description":"AMI の作成","elapsed_seconds":120,"state":"pending",...}
  class ProgressLogger
    def initialize(logger:, description:, interval_seconds:,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @logger = logger
      @description = description
      @interval_seconds = interval_seconds
      @clock = clock
      @started = clock.call
      @last_reported = nil
    end

    def report
      now = @clock.call
      return if @last_reported && now - @last_reported < @interval_seconds

      @last_reported = now
      fields = block_given? ? yield : {}
      @logger.info("waiting", description: @description, elapsed_seconds: (now - @started).round, **fields)
    end
  end
end
