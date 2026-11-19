# frozen_string_literal: true

# EC2・Route 53・DB のサーバーリストの照合（list_instances.rb の --hosted-zone-id・--server-list）。
# AWS には触らない（AWS から引いた値を受け取って突き合わせるだけ）。照合の決まりは README の「サーバーリストとの照合」。
#
#   EC2（パブリック IP・分類のタグ）─ IP ─ Route 53（A レコード: IP → 名前）─ 名前 ─ DB のサーバーリスト（ホスト名・サーバータイプ）
#
# 差分は警告の文として返すだけで、一覧に入れる台は変えない。
module ServerListCheck
  module_function

  # 名前を比べられる形にする（大文字・小文字と、末尾の . を区別しない）
  def normalize(name)
    name.to_s.strip.downcase.chomp('.')
  end

  # サーバーリストのホスト名と Route 53 の名前が同じ台を指すか。
  # ホスト名が FQDN（. を含む）なら名前全体を、短い名前なら Route 53 の名前の最初のラベルと比べる
  def host_matches?(host, dns_name)
    host = normalize(host)
    dns_name = normalize(dns_name)
    host.include?('.') ? host == dns_name : host == dns_name.split('.').first
  end

  # サーバーリスト（TSV）を読む。1 行目（# と空の行を除く）が見出しで、ホスト名とサーバータイプの列を見出しの名前で選ぶ。
  # 形が合わなければ ArgumentError（理由の文）
  def read_server_list(path, host_column, type_column)
    lines = File.readlines(path, chomp: true).reject { |line| line.strip.empty? || line.start_with?('#') }
    raise ArgumentError, "#{path}: 見出しの行がない" if lines.empty?

    header = lines.first.split("\t").map(&:strip)
    indexes = [host_column, type_column].map do |column|
      header.index(column) or raise ArgumentError, "#{path}: 見出しに #{column} の列がない（見出し: #{header.join(', ')}）"
    end
    lines.drop(1).map do |line|
      cells = line.split("\t")
      { host: cells[indexes[0]].to_s.strip, type: cells[indexes[1]].to_s.strip }
    end.reject { |server| server[:host].empty? }
  end

  # 照合する。
  #   instances: [{ id:, label:, public_ip:（なければ nil）, type:（分類のタグの値。なければ nil） }]（環境のタグが合う台すべて）
  #   ip_names:  { パブリック IP => [Route 53 の名前, ...] }
  #   servers:   read_server_list の結果（サーバーリストを渡さないなら nil）
  #   type_tag_key: 分類のタグのキー（nil なら分類は比べない）
  # 戻り値: [{ インスタンス ID => [Route 53 の名前, ...] }, [警告の文, ...]]
  def check(instances, ip_names, servers, type_tag_key)
    warnings = duplicate_host_warnings(servers)
    dns_names = {}
    matched = []
    instances.each do |instance|
      names = instance[:public_ip] ? ip_names.fetch(instance[:public_ip], []) : []
      dns_names[instance[:id]] = names
      hits = servers ? servers.select { |server| names.any? { |name| host_matches?(server[:host], name) } } : []
      matched.concat(hits)
      warnings.concat(instance_warnings(instance, names, servers, hits, type_tag_key))
    end
    (servers || []).each do |server|
      next if matched.any? { |hit| hit.equal?(server) }

      warnings << "EC2（環境のタグ）にない: #{server[:host]}（#{server[:type]}）"
    end
    [dns_names, warnings]
  end

  # 1 台ぶんの警告
  def instance_warnings(instance, names, servers, hits, type_tag_key)
    who = "#{instance[:id]}（#{instance[:label]}）"
    return ["#{who}: パブリック IP がない（Route 53 と突き合わせられない）"] unless instance[:public_ip]
    return ["#{who}: Route 53 に名前がない（#{instance[:public_ip]}）"] if names.empty?

    warnings = []
    warnings << "#{who}: Route 53 の名前が複数ある（#{names.join(', ')}）" if names.size > 1
    return warnings unless servers
    return warnings + ["#{who}: DB のサーバーリストにない（#{names.join(', ')}）"] if hits.empty?
    return warnings unless type_tag_key
    return warnings + ["#{who}: 分類のタグがない（#{type_tag_key}）"] if instance[:type].nil?

    warnings + hits.reject { |server| server[:type] == instance[:type] }.map do |server|
      "#{who}: 分類が違う（タグ #{type_tag_key}=#{instance[:type]}、DB の #{server[:host]} は #{server[:type]}）"
    end
  end

  # サーバーリストの中の、同じホスト名の重複
  def duplicate_host_warnings(servers)
    (servers || []).group_by { |server| normalize(server[:host]) }.select { |_, rows| rows.size > 1 }.map do |_, rows|
      "サーバーリストに同じホスト名が 2 回ある: #{rows.first[:host]}"
    end
  end
end
