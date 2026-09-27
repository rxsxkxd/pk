# frozen_string_literal: true

module AmiPublish
  class Error < StandardError; end

  # 使い方・設定値の誤り。終了コード 2
  class ConfigurationError < Error; end

  # ステップが望ましい状態に到達できなかった（AMI 作成の失敗、ヘルスチェックの失敗、想定外の差分など）。終了コード 1
  class StepFailedError < Error; end
end
