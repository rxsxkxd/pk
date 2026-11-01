# frozen_string_literal: true

require_relative 'al2_update'
require_relative 'remote_result'

# 1 台の更新の結果（rb/update.rb が使う）。更新の前（before）と後（after）の状態を比べて、
# 残りを止める問題（httpd が止まった、アプリが応答しなくなった、更新の失敗）と、止めずに知らせる注意（再起動が要る、
# mod_ssl のリンク先の libssl が変わった など）に分け、表示と記録の形にする。
class UpdateOutcome
  attr_reader :id

  def initialize(id, before, after)
    @id = id
    @before = before
    @after = after
  end

  # 更新した（問題なし）・問題あり（更新はしたが、前に動いていたものが動かない）・失敗（更新できなかった）
  def status
    return '失敗' if @after.problem
    return '問題あり' unless problems.empty?

    '更新した'
  end

  # 残りの台を止める問題（前は良かったのに、後で悪くなったものだけ。前から悪ければ注意に回す）
  def problems
    return [@after.problem] if @after.problem

    list = []
    list << "httpd が動いていない（#{@after['httpd_active']}）" if httpd_stopped?
    list << "アプリの応答が #{@before['health_code']} から #{@after['health_code']} に変わった" if health_lost?
    list
  end

  # 止めずに知らせること
  def warnings
    list = []
    list << "mod_ssl の libssl が #{@before['mod_ssl_libssl']} から #{@after['mod_ssl_libssl']} に変わった" if libssl_changed?
    list << '再起動が要る（道具では再起動しない。README の「再起動」を見る）' if @after['needs_reboot'] == 'yes'
    list << "前から httpd が動いていない（#{@before['httpd_active']}）" if @before['httpd_active'] != 'active'
    list << '出力が 24,000 文字で切れた（一覧は途中まで。台の /var/log/al2-update/ を見る）' unless @after.complete?
    list
  end

  def print_report
    puts "#{status}  #{@id}  #{@after.problem || counts_line}"
    @after.problem ? print_failure_detail : print_details
  end

  # 記録（JSON）に書く形
  def to_h
    { 'status' => status, 'problems' => problems, 'warnings' => warnings, 'yum_history' => @after['yum_history'],
      'log' => @after['log'], 'updated' => @after.entries('updated'), 'installed' => @after.entries('installed'),
      'removed' => @after.entries('removed'), 'needs_reboot' => @after['needs_reboot'],
      'restart_services' => @after['restart_services'], 'kernel_running' => @after['kernel_running'],
      'kernel_newest' => @after['kernel_newest'] }
  end

  private

  def print_failure_detail
    puts "   yum の出力（台の中） #{@after['log'] || 'なし（更新の前に止まった）'}"
  end

  def print_details
    puts "   #{@after.status_line}", "   #{@after.restart_services_line}", "   #{@after.versions_line}"
    print_changes
    problems.each { |problem| puts "   問題: #{problem}" }
    warnings.each { |warning| puts "   注意: #{warning}" }
  end

  def counts_line
    "更新 #{@after['updated_count']} 件、新しく入った #{@after['installed_count']} 件、" \
      "取り除いた #{@after['removed_count']} 件（yum の履歴の ID #{@after['yum_history'] || 'なし'}、" \
      "yum の出力 #{@after['log']}）"
  end

  def print_changes
    { 'updated' => '更新    ', 'installed' => '新しく  ', 'removed' => '取り除き' }.each do |key, label|
      @after.entries(key).each { |entry| puts "   #{label}  #{AL2Update.with_attention(entry)}" }
    end
  end

  def httpd_stopped?
    @before['httpd_active'] == 'active' && @after['httpd_active'] != 'active'
  end

  def health_lost?
    healthy?(@before['health_code']) && !healthy?(@after['health_code'])
  end

  # 2xx・3xx を応答ありとみなす（転送は追わない）
  def healthy?(code)
    /\A[23]\d\d\z/.match?(code.to_s)
  end

  def libssl_changed?
    @before['mod_ssl_libssl'] != @after['mod_ssl_libssl']
  end
end
