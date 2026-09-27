# frozen_string_literal: true

module AmiPublish
  # ステップを順番に実行する。どこかで失敗したら、以降のステップは実行しない。
  class StepRunner
    def initialize(steps:, logger:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @steps = steps
      @logger = logger
      @clock = clock
    end

    def run(context)
      @steps.each { |step| run_step(step, context) }
      context
    end

    private

    def run_step(step, context)
      name = step.class.name.split("::").last
      started = @clock.call
      @logger.info("step_started", step: name, dry_run: context.dry_run)
      step.call(context)
      @logger.info("step_finished", step: name, duration_seconds: (@clock.call - started).round(1))
    rescue StandardError => e
      @logger.error("step_failed", step: name, error_class: e.class.name, message: e.message,
                                   duration_seconds: (@clock.call - started).round(1))
      raise
    end
  end
end
