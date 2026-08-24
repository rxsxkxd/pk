# 暫定対応: アプリ（Rails 4.2・Ruby 2.7）で国内と特定の IP に絞る

> 位置付け: 今の環境（Amazon Linux 2・Apache 2.4.56・Passenger・Rails 4.2・Ruby 2.7.7）に入れる**暫定対応**の検討。AL2023 での作り直し（[今の構成を AL2023 で作り直す検討](../../initial-image-build/existing-system-rebuild-on-al2023.md)）とは別に考える。**動かして確かめてはいない**。
>
> 同じ要件のほかの層: [OS（iptables ＋ ipset、または firewalld）で絞る](./access-restriction-os-firewall.md)、[Apache で絞る](./access-restriction-apache.md)
>
> 作成日: 2026-10-28

## 要件

対象（アプリ全体、または特定の画面や機能）について、**国内（日本）からのアクセスは全体を許可し、海外からのアクセスはすべて絞る**。数件の IP を許可するだけでは足りないので、国で判定することが本命になる。日本以外から通す必要がある少数の相手（海外の拠点、外部サービス、外形監視など）は、**許可する IP** として補助的に足す。絞ったリクエストには 403 を返す。

## 結論

| # | 結論 |
|---|---|
| 1 | **Rack::Attack**（6.8.0）でリクエストを止め、国の判定には MaxMind の公式の **`maxmind-db`**（1.2.0）と GeoLite2 のデータベースを使う形を勧める。どちらも Rails 4.2・Ruby 2.7 で使える版がある |
| 2 | アプリで絞る利点は、**業務の条件と組み合わせられる**こと（ログインした利用者の種類、機能、時間帯など）。IP と国だけで絞るなら、[OS](./access-restriction-os-firewall.md) や [Apache](./access-restriction-apache.md) の方が手前で止まり、コードの変更も要らない |
| 3 | 効くのは **Rails まで届くリクエストだけ**。Apache が直接返す静的なファイル（`public/` の下、assets など）には効かない |
| 4 | Gemfile と `Gemfile.lock` を変えてリリースする必要がある。Rails 4.2 の古い依存の中に足すので、`bundle install` の結果（ほかの gem が動かないか）を確かめる |

## 使う gem（Ruby 2.7・Rails 4.2 で使える版）

| gem | 版 | 条件 | 役割 |
|---|---|---|---|
| `rack-attack` | 6.8.0（2025-10） | Ruby 2.4 以上、`rack >= 1.0, < 4`（Rails 4.2 の Rack 1.6 を満たす） | リクエストを止める（blocklist）・通す（safelist）。Rails では自動でミドルウェアに入る（Railtie） |
| `maxmind-db` | **1.2.0**（2023-11） | Ruby 2.5 以上。1.3 以降は Ruby 3.0 以上が要るので、**1.2.0 に固定する** | GeoLite2 のデータベース（`.mmdb`）を読む。依存する gem はない |

```ruby
# Gemfile
gem 'rack-attack', '~> 6.8'
gem 'maxmind-db', '1.2.0'
```

データベースの取得と更新（MaxMind のアカウント、`geoipupdate`、cron）は [Apache の場合](./access-restriction-apache.md#12-データベースの取得と更新geoipupdate) と同じ。Apache とアプリの両方で使うなら、同じファイル（`/usr/share/GeoIP/GeoLite2-Country.mmdb`）を共有する。

## 実装

### 許可する IP と国の判定

```ruby
# lib/access_guard.rb
require 'ipaddr'
require 'maxmind/db'

# 許可する IP と、日本からのアクセスかの判定
module AccessGuard
  ALLOW_FILE = ENV.fetch('ACCESS_GUARD_ALLOW_FILE', '/etc/access-guard/allow.txt')
  COUNTRY_DB = ENV.fetch('ACCESS_GUARD_COUNTRY_DB', '/usr/share/GeoIP/GeoLite2-Country.mmdb')
  ALLOWED_COUNTRIES = %w[JP].freeze

  module_function

  def enabled?
    ENV['ACCESS_GUARD_ENABLED'] != 'false'
  end

  # 対象のパス（全体なら常に true）
  def target?(path)
    path.start_with?('/admin')
  end

  def allowed?(ip)
    allowed_ip?(ip) || ALLOWED_COUNTRIES.include?(country_code(ip))
  end

  def allowed_ip?(ip)
    address = IPAddr.new(ip)
    allow_list.any? { |range| range.include?(address) }
  rescue IPAddr::InvalidAddressError
    false
  end

  def country_code(ip)
    record = reader.get(ip)
    record && record['country'] && record['country']['iso_code']
  rescue ArgumentError
    nil
  end

  def allow_list
    @allow_list ||= File.readlines(ALLOW_FILE)
                        .map { |line| line.sub(/#.*/, '').strip }
                        .reject(&:empty?)
                        .map { |entry| IPAddr.new(entry) }
  end

  def reader
    @reader ||= MaxMind::DB.new(COUNTRY_DB, mode: MaxMind::DB::MODE_MEMORY)
  end
end
```

### Rack::Attack の設定

```ruby
# config/initializers/rack_attack.rb
require 'access_guard'

Rack::Attack.enabled = AccessGuard.enabled?

Rack::Attack.blocklist('access guard: outside Japan and not allowed') do |request|
  # 前段がないので、接続元の IP（REMOTE_ADDR）をそのまま使う
  ip = request.env['REMOTE_ADDR']
  AccessGuard.target?(request.path) && !AccessGuard.allowed?(ip)
end

Rack::Attack.blocklisted_responder = lambda do |_request|
  [403, { 'Content-Type' => 'text/plain' }, ["Forbidden\n"]]
end

# 止めたリクエストをログに残す
ActiveSupport::Notifications.subscribe('blocklist.rack_attack') do |_name, _start, _finish, _id, payload|
  request = payload[:request]
  ip = request.env['REMOTE_ADDR']
  Rails.logger.warn("[access guard] blocked ip=#{ip} country=#{AccessGuard.country_code(ip).inspect} path=#{request.path}")
end
```

| 点 | 内容 |
|---|---|
| 接続元の IP | `request.ip` は、条件によって `X-Forwarded-For` の値を使う。利用者が書き換えられる値なので、前段がない今の構成では `REMOTE_ADDR` を直接使う |
| 許可する IP のファイル | アプリの外（`/etc/access-guard/allow.txt`）に置き、サーバーごとに変えられるようにする。書式は [OS の場合](./access-restriction-os-firewall.md) の `allow.txt` と同じ（1 行 1 件、CIDR 可、`#` から後はコメント） |
| 一時的に止める | 環境変数 `ACCESS_GUARD_ENABLED=false` で、コードを変えずに制限を止められる（Passenger の `SetEnv` や `PassengerAppEnv` まわりの設定で渡し、アプリを再起動する） |
| 画面や機能で絞る | 特定のコントローラーだけなら、Rack::Attack ではなく `before_action` で `AccessGuard.allowed?(request.env['REMOTE_ADDR'])` を見て `head :forbidden` を返す形でもよい。ログインした利用者の種類などと組み合わせられる |

## Passenger との関係

| 点 | 内容 |
|---|---|
| メモリ | `MODE_MEMORY` は、データベース（GeoLite2-Country は数 MB）をプロセスごとにメモリに読み込む。Passenger の既定（smart spawning）では、読み込み済みのプロセスから fork するので、**最初のリクエストより前に読み込んでおけば**、プロセス間で共有される。initializer の最後で `AccessGuard.reader` を呼んでおく |
| データベースの更新 | 読み込んだプロセスは、ファイルが更新されても古い中身のまま。`geoipupdate` の後に `passenger-config restart-app <アプリのディレクトリ>` でプロセスを入れ替える（cron で続けて実行する） |
| 許可する IP の更新 | 同じく、ファイルを変えたらアプリを再起動する |

```bash
# cron の例（データベースの更新の後に、アプリのプロセスを入れ替える）
23 5 * * * root /usr/bin/geoipupdate && /path/to/passenger-config restart-app /path/to/app
```

## 確認

| 段階 | 方法 |
|---|---|
| テスト | MaxMind が公開しているテスト用のデータベース（MaxMind-DB のリポジトリの `GeoIP2-Country-Test.mmdb`）を `ACCESS_GUARD_COUNTRY_DB` で指し、`REMOTE_ADDR` を変えたリクエストのテストを書く |
| 手元・ステージング | `ACCESS_GUARD_ALLOW_FILE` に自分の IP を入れた場合と入れない場合で、対象のパスが 200 と 403 になるかを見る |
| 本番 | 許可した IP、日本の一般の回線、海外（例: 海外のリージョンの EC2）から `curl -sI https://<ホスト名>/admin` を実行し、Rails のログの `[access guard] blocked` を見る |

## 外す（元に戻す）

| 範囲 | やり方 |
|---|---|
| すぐに止める | `ACCESS_GUARD_ENABLED=false` にしてアプリを再起動する |
| 仕組みごと外す | Gemfile と initializer を戻してリリースする |

## 気を付けること

| 点 | 内容 |
|---|---|
| 効く範囲 | Rails まで届くリクエストだけ。Apache が直接返す `public/` の下のファイルには効かない。SSH などのほかのポートにも効かない |
| 処理の手前で止まらない | Apache と Passenger がリクエストを受け、Rails のプロセスまで届いてから断る。大量のアクセスを止める用途には向かない |
| 位置の判定は完全ではない | 海外にいる日本の利用者、VPN、海外の外形監視、外部サービスからの通知（webhook）は「日本以外」になりうる。必要な相手は許可する IP に足す |
| 依存の追加 | Rails 4.2 のアプリに gem を 2 つ足す。`bundle install` で、ほかの gem の版が動かないことを `Gemfile.lock` の差分で確かめる |
| 古い版への固定 | `maxmind-db` は Ruby 2.7 で使える最後の 1.2.0 に固定する（1.3 以降は入らない） |

## 決めること

| # | 論点 | 選択肢 |
|---|---|---|
| R1 | 絞る範囲 | アプリ全体 / 特定のパス / 特定の画面や機能（`before_action`） |
| R2 | 業務の条件と組み合わせるか | IP と国だけ / ログインした利用者の種類などと組み合わせる |
| R3 | 許可する IP の一覧の置き場所 | サーバーのファイル（勧める） / アプリの設定 / 環境変数 |
| R4 | データベースを Apache と共有するか | Apache でも国で絞るなら、同じファイルと同じ更新の仕組みを使う |

## 参考

- [rack/rack-attack](https://github.com/rack/rack-attack)（blocklist、`blocklisted_responder`、`blocklist.rack_attack` の通知、Railtie）
- [maxmind-db - RubyGems](https://rubygems.org/gems/maxmind-db)（1.2.0 は Ruby 2.5 以上、1.3 以降は Ruby 3.0 以上）、[MaxMind-DB-Reader-ruby](https://github.com/maxmind/MaxMind-DB-Reader-ruby)
- [maxmind/MaxMind-DB](https://github.com/maxmind/MaxMind-DB)（テスト用のデータベース）
- [GeoLite2 の無料のデータベース](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data)
