# タイムゾーン差異のドライバ検証（Ruby / mysql2）— 収集のみ。
#
# 本スクリプトは観測した事実を reports/ruby.json へ書き出すだけであり、
# 合否の判定とレポート生成は行わない。判定は generate_report.rb が担当する。
#
# mysql2 はサーバーへ SET time_zone を発行しない。database_timezone は
# 「DB 側の値がどのタイムゾーンで保存されていると仮定するか」を決める Ruby 側の設定であり、
# :utc か :local しか受け付けない。レプリカ（セッション Asia/Tokyo）に合わせるには
# :local を使い、プロセスの TZ を Asia/Tokyo にしておく必要がある。

require 'json'
require 'time'
require 'fileutils'
require 'mysql2'

SQL_ROWS = 'SELECT id, ts, UNIX_TIMESTAMP(ts) AS server_epoch FROM t ORDER BY id'
SQL_WHERE = "SELECT COUNT(*) AS c FROM t WHERE ts >= '2026-09-03 00:00:00'"
SQL_GROUPS = 'SELECT COUNT(*) AS c FROM (SELECT DATE(ts) FROM t GROUP BY DATE(ts)) g'

def client(host, database_timezone)
  Mysql2::Client.new(
    host: host,
    port: Integer(ENV.fetch('MYSQL_PORT', '3306')),
    username: ENV.fetch('MYSQL_USER', 'root'),
    password: ENV.fetch('MYSQL_PWD'),
    database: ENV.fetch('MYSQL_DATABASE', 'tzcheck'),
    database_timezone: database_timezone,
    application_timezone: :utc
  )
end

# 読み取り値をドライバがどう解釈したかを収集する。
def collect_read(label, host, database_timezone)
  c = client(host, database_timezone)
  session_tz = c.query('SELECT @@session.time_zone AS tz').first['tz']
  section = "#{label} / database_timezone=#{database_timezone.inspect}"
  detail = "session_time_zone=#{session_tz}, プロセス TZ=#{ENV['TZ'] || '(未設定)'}"

  c.query(SQL_ROWS).map do |row|
    {
      'section' => section, 'detail' => detail, 'id' => row['id'],
      'driver_value' => row['ts'].strftime('%Y-%m-%d %H:%M:%S %z'),
      'driver_unix' => row['ts'].to_i, 'server_unix' => row['server_epoch']
    }
  end
ensure
  c&.close
end

# サーバー側で確定する結果を収集する。
def collect_server_side(label, host, database_timezone)
  c = client(host, database_timezone)
  {
    'label' => label,
    'setting' => "database_timezone=#{database_timezone.inspect}",
    'where_matched' => c.query(SQL_WHERE).first['c'],
    'date_groups' => c.query(SQL_GROUPS).first['c']
  }
ensure
  c&.close
end

source_host = ENV.fetch('SOURCE_HOST', 'source')
replica_host = ENV.fetch('REPLICA_HOST', 'replica')

collection = {
  'schema_version' => 1,
  'language' => 'Ruby',
  'driver' => "mysql2 #{Mysql2::VERSION}",
  'timezone_layer' => '`database_timezone` / `application_timezone`（`:utc` か `:local` のみ）',
  'issues_set_time_zone' => false,
  'setting_label' => 'database_timezone',
  'collected_at' => Time.now.utc.iso8601,
  # 接続先のセッション time_zone に合わせる。レプリカは :local ＋ プロセス TZ=Asia/Tokyo。
  'read_results' => collect_read('source', source_host, :utc) +
                    collect_read('replica', replica_host, :local),
  'contrast' => {
    'title' => 'レプリカに `database_timezone=:utc`（不一致）で接続した場合',
    'results' => collect_read('replica', replica_host, :utc)
  },
  'server_side' => [
    collect_server_side('source', source_host, :utc),
    collect_server_side('source', source_host, :local),
    collect_server_side('replica', replica_host, :utc),
    collect_server_side('replica', replica_host, :local)
  ]
}

dir = ENV.fetch('REPORT_DIR', '/probe/reports')
FileUtils.mkdir_p(dir)
path = File.join(dir, 'ruby.json')
File.write(path, JSON.pretty_generate(collection) + "\n")

puts "収集完了: #{path}（#{collection['read_results'].size} 行 / " \
     "対比 #{collection['contrast']['results'].size} 行 / " \
     "サーバー側 #{collection['server_side'].size} 件）"
puts 'レポート生成: docker compose run --rm probe-report'
