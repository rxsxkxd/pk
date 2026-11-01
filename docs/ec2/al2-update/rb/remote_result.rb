# frozen_string_literal: true

require_relative 'al2_update'

# インスタンスに送ったスクリプトの結果（get-command-invocation）を読む。
# 結果の行: "PG <キー>=<値>"（同じキーが何行もあれば、一覧として読める）、"PGSTEP <段階>"、"PG blocked=<理由>"。
class RemoteResult
  def initialize(result)
    @result = result
    @output = result.to_h['StandardOutputContent'].to_s
    @values = @output.scan(/^PG (\w+)=(.*)$/).to_h
  end

  # 問題の説明（インスタンスの側の確認で止まった理由か、実行の失敗。問題がなければ nil）
  def problem
    blocked = entries('blocked')
    return blocked.join(' / ') unless blocked.empty?

    failure
  end

  # キーの値（同じキーが何行もあれば、最後の値）
  def [](key)
    @values[key]
  end

  # 同じキーの行の値を、すべて並べて返す（更新される予定のパッケージなど）
  def entries(key)
    @output.scan(/^PG #{Regexp.escape(key)}=(.*)$/).flatten
  end

  # 更新される予定（check-updates.sh の pending）のうち、除くパッケージを除いた一覧（"<名前>.<アーキテクチャ> <版>"）
  def updates(excludes)
    entries('pending').reject { |entry| AL2Update.matches?(entry.split.first, excludes) }
  end

  # 出力が 24,000 文字で切れずに、最後まで返ったか
  def complete?
    self['output_end'] == 'yes'
  end

  # 今の状態の 1 行の説明（status.sh の値）
  def status_line
    "再起動が要る #{self['needs_reboot']}  httpd #{self['httpd_active']}  アプリの応答 #{self['health_code']}  " \
      "mod_ssl の libssl #{self['mod_ssl_libssl']}  カーネル 動いている #{self['kernel_running']} / " \
      "入っている最新 #{self['kernel_newest']}"
  end

  # 動いているが、更新で古いライブラリを使ったままになっているサービス（needs-restarting -s）
  def restart_services_line
    services = self['restart_services'].to_s
    "再起動が要るサービス #{services.empty? ? 'なし' : services}"
  end

  # 版の 1 行の説明（httpd・mod_ssl・openssl）
  def versions_line
    keys = %w[httpd mod_ssl openssl_libs openssl11_libs]
    "版 #{keys.map { |key| "#{key} #{self["version_#{key}"]}" }.join('  ')}"
  end

  private

  def failure
    return '結果が返らない（待ちきれない）' unless @result
    return nil if @result['Status'] == 'Success'

    step = @output.scan(/^PGSTEP (.*)$/).flatten.last || '（開始前）'
    detail = @result['StandardErrorContent'].to_s.lines.last.to_s.strip
    "「#{step}」で #{@result['Status']}（#{detail.empty? ? 'エラーの出力なし' : detail}）"
  end
end
