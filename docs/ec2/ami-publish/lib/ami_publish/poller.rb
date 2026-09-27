# frozen_string_literal: true

module AmiPublish
  # 条件を満たすまで一定間隔で確認する。AWS SDK に待機処理（waiter）がない確認に使う。
  class Poller
    class TimeoutError < StandardError; end

    def initialize(interval_seconds:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   sleeper: ->(seconds) { sleep(seconds) })
      @interval_seconds = interval_seconds
      @clock = clock
      @sleeper = sleeper
    end

    # ブロックが真を返すまで繰り返す。timeout_seconds を過ぎたら TimeoutError。
    def wait(timeout_seconds:, description:)
      deadline = @clock.call + timeout_seconds
      loop do
        return if yield
        raise TimeoutError, "#{description}が #{timeout_seconds} 秒以内に完了しなかった" if @clock.call >= deadline

        @sleeper.call(@interval_seconds)
      end
    end
  end
end
