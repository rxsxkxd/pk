# Rails 5 / Ruby 2.7 をセキュリティ更新のある OS で動かす

> 位置づけ: 設計と Dockerfile の雛形。**まだビルドして確かめていない**（確かめ方は 9 章、未確認の点は [OPEN_ITEMS.md](OPEN_ITEMS.md)）。確認日 2026-10-23。

## 1. 前提（プロジェクト内の資料から）

| 資料 | 分かること |
|---|---|
| [1.md](1.md) | 今は `ruby:2.7.4-bullseye` を使っている。証明書が新しくならず、`SSL_CERT_FILE` で curl の `cacert.pem` を指す回避策を検討していた。アプリは `/api` に置いている。`nodejs`・`default-mysql-client` を入れている |
| [integrated-management-system/01](../app/integrated-management-system/01-current-state.md)・[06](../app/integrated-management-system/06-platform-options.md) | 統合管理システムは Rails 5。当面は版を据え置く（選択肢 a）。Rails 5 と Ruby 2.x は、すでにセキュリティ修正の提供が終わっている |
| [integrated-management-system/09](../app/integrated-management-system/09-batch-on-ecs.md) | バッチは EventBridge Scheduler → Step Functions → ECS on Fargate で、Web と**同じコンテナイメージ**を起動コマンドだけ変えて動かす。そのためにまず Dockerfile が要る |
| [rds_mysql_upgrade](../rds_mysql_upgrade/README.md) | 接続先の RDS for MySQL は 8.4 へ移る。8.4 の既定の認証方式は `caching_sha2_password` |

## 2. 結論

- **OS は Debian 13（trixie）**。ベースイメージは `public.ecr.aws/docker/library/debian:trixie-slim`。
- **Ruby 2.7.8 をソースから組む**。2.7 系の最後の版で、今の 2.7.4 からはパッチの差だけ。
- Ruby 2.7 同梱の openssl 拡張は OpenSSL 3 で組めないため、**openssl gem 3.3 系の拡張に差し替えて、OS の OpenSSL 3 を使う**。OpenSSL 1.1.1 を同梱する方法は取らない（1.1.1 は 2023 年 9 月で更新が終わっている）。
- イメージは 2 段にする。
  - **Ruby のベースイメージ**（`ruby-base/Dockerfile`）: 公式の `ruby` / `ruby-slim` の代わり。
  - **アプリのイメージ**（`app/Dockerfile`）: 今の Dockerfile の `FROM` を差し替える形。
- 証明書は OS の `ca-certificates` を、イメージを作り直すたびに更新して使う。**`SSL_CERT_FILE` の回避策は要らなくなる**（6 章）。
- これで直るのは **OS と OpenSSL が古いことによるリスクだけ**。Rails 5 と Ruby 2.7 自体のリスクは残る（8 章）。

## 3. OS の選定

| 観点 | Debian 13 trixie | Debian 12 bookworm | Amazon Linux 2023 |
|---|---|---|---|
| セキュリティ更新の期限 | セキュリティチーム 〜2028-08、**LTS 〜2030-06-30** | すでに LTS（2026-06-11 〜 **2028-06-30**）。対象のパッケージが絞られる | **2029-06-30** |
| OpenSSL | 3.5 | 3.0 | 3.x |
| GCC（Ruby 2.7 と古い gem を組むとき） | 14。古い C の書き方がエラーになるため、`-fpermissive` で警告に戻す | 12。そのまま組める見込み | 11。そのまま組める見込み |
| パッケージの揃い | 広い | 広い | 狭い（EPEL もない）。画像処理などのライブラリが足りないことがある |
| 今の構成からの移りやすさ | Debian 系なのでパッケージ名・手順が近い | 同左 | `dnf` とパッケージ名を全部書き換える |
| AWS との相性 | ECR Public のミラーから取れる | 同左 | AWS 製。ECR Public から取れる |

- **trixie を選ぶ理由**: 期限が最も長く、今の Debian 系の手順を引き継げる。アプリの gem が要求するライブラリが未調査なので、パッケージの揃っている Debian のほうが安全。
- **bookworm は戻り先**: GCC 14 で組めない gem が出たときの逃げ道。そのときは `DEBIAN_IMAGE` と、`slim` の段のパッケージ名（`libssl3t64` → `libssl3`）、`CFLAGS` の `-fpermissive` を直す。
- **Amazon Linux 2023 は選ばない**: コンパイラが古く、Ruby 2.7 を組むには楽。ただし期限は trixie の LTS より短く、パッケージも少ない。手順をすべて書き換えることになる。AL2023 の「クローン」に当たる配布物はないため、候補は AL2023 そのものになる。

## 4. Ruby 2.7 を新しい OS で組むときの問題と対処

### 4.1 OpenSSL 3

- Ruby 2.7 に同梱の openssl 拡張（2.1 系）は OpenSSL 1.1 までにしか対応していない。新しい OS には OpenSSL 3 しかない。
- **対処**: Ruby のソースの `ext/openssl` を、openssl gem 3.3.3（`required_ruby_version >= 2.7.0`）の拡張と `lib/` に置き換えてから組む。
  - gem を後から入れる方法は取らない。Gemfile に `openssl` を書かないと、`bundle exec` の中で読めなくなるため。
  - 置き換えた拡張は標準ライブラリとして入り、default gem としては登録されない（`gem list openssl` に出ない）。アプリの Gemfile.lock に `openssl` gem があれば、そちらが優先される。
  - 4.0 系も Ruby 2.7 に対応しているが、大きな変更を含むため避けた。
- **アプリへの影響**（OPEN_ITEMS.md で確かめる）:
  - openssl gem 3.x では `OpenSSL::PKey` が変更できなくなった（`set_key` などが例外になる）。`OpenSSL::` を直接使うコードと、jwt・ruby-saml・net-ssh などの古い版が影響を受けうる。
  - OpenSSL 3 の既定のセキュリティレベルでは、外部への古い TLS や弱い鍵・署名（SHA-1、2048 bit 未満の RSA）が拒否される。

### 4.2 GCC 14

- GCC 14 では、暗黙の関数宣言・互換でないポインタの型・int への変換が、既定でエラーになった。Ruby 2.7 本体と、古い gem のネイティブ拡張（mysql2・nokogiri・puma・ffi などの古い版）が引っかかりうる。
- **対処**: `CFLAGS='-O2 -fpermissive'` で組む。この値は `RbConfig` に残るので、`bundle install` で組む gem にも効く。それでも組めない gem があれば、gem の版を上げるか、bookworm に戻す。

### 4.3 RubyGems と Bundler

| 部品 | 版 | 理由 |
|---|---|---|
| RubyGems | 3.4.22 | Ruby 2.7 に対応する最後の版（3.5 以降は Ruby 3.0 以上） |
| Bundler | 2.4.22（`BUNDLER_VERSION` で変える） | 同上。ただし **Rails 5.0 / 5.1 は Bundler 2 を受け付けない**（railties の依存が `bundler < 2.0`）。その場合は 1.17.3 にする。Gemfile.lock の `BUNDLED WITH` に合わせる |

### 4.4 入れない拡張

readline・gdbm の開発用ヘッダーは入れないので、この 2 つの拡張は組まれない。irb は Ruby 2.7 同梱の reline で動く。

## 5. イメージの構成

```
ruby-base/Dockerfile                      app/Dockerfile（アプリのリポジトリのルートに置く）
┌──────────────────────────────┐
│ build                        │  FROM ─▶  gems    : libmariadb-dev、bundle install
│  debian:trixie-slim          │                │
│  ＋コンパイラ・開発用ヘッダー │                ▼
│  ＋Ruby 2.7.8（OpenSSL 3）    │           assets  : nodejs、assets:precompile
│  ＋RubyGems 3.4.22・Bundler   │                │ /api（アセット込み）
└──────────────┬───────────────┘                │
               │ /usr/local                      ▼
┌──────────────▼───────────────┐  FROM ─▶  runtime : libmariadb3、nodejs、mysql クライアント、
│ slim                         │                     RDS の CA、rails ユーザー
│  debian:trixie-slim          │                     ／usr/local/bundle と /api を入れる
│  ＋実行用ライブラリ＋Ruby     │
└──────────────────────────────┘
```

- **ベースを分ける理由**: Ruby のコンパイルは時間がかかるが、変わるのは OS の更新のときだけ。アプリのビルドから外せば、アプリのイメージは gem とコードの分だけで済む。今の Dockerfile が公式の `ruby` のイメージを `FROM` にしているので、置き場所（`GEM_HOME=/usr/local/bundle` など）を公式にそろえ、`FROM` の差し替えで移れるようにした。
- タグ: `ruby27:2.7.8-trixie`（build）、`ruby27:2.7.8-trixie-slim`（slim）。ECR では作り直した日付のタグ（例: `2.7.8-trixie-slim-20261023`）も付け、アプリはその日付のタグで固定する。
- 実行時の設定:
  - `RAILS_LOG_TO_STDOUT=1`（CloudWatch Logs に集める）、`RAILS_SERVE_STATIC_FILES=1`（ALB から直接受ける場合）。
  - 秘密の値（`SECRET_KEY_BASE`・`RAILS_MASTER_KEY`・DB のパスワード）は、イメージに入れずにタスク定義の `secrets` で渡す。
- 起動コマンド: Web は `bundle exec puma -C config/puma.rb`。バッチはタスク定義の `command` で `bin/rails runner ...` などに上書きする。
- ビルドの中で、ネイティブ拡張が使う共有ライブラリが揃っているかを `ldd` で確かめ、足りなければビルドを止める。

## 6. 証明書（1.md の件の整理）

- **新しくならなかった原因**: `ruby:2.7.4` のイメージは 2021 年に作られたまま更新されていない。そのうえ bullseye の LTS は **2026-08-31 で終わった**ため、apt でも新しい `ca-certificates` は入らない。OpenSSL も 1.1.1 のままである。
- **`SSL_CERT_FILE` について**: Ruby の OpenSSL・RubyGems・Bundler・Net::HTTP は、確かにこの環境変数で CA のファイルを差し替えられる。ただし直るのは CA の一覧だけで、OS と OpenSSL の更新が止まっていることは変わらない。CA の一覧を自分で更新し続ける手間も残る。
- **この設計での扱い**:
  - Ruby は OS の OpenSSL を使うので、CA は OS の `ca-certificates`（`/etc/ssl/certs`）を見る。イメージを作るたびに `apt-get upgrade` で最新にする。`SSL_CERT_FILE` は設定しない。
  - **RDS の CA は OS の一覧に入っていない**。`/etc/ssl/rds/global-bundle.pem` に置き、`database.yml` の `sslca` で指す。

## 7. AWS での動かし方

| 項目 | 方針 |
|---|---|
| 実行環境 | ECS on Fargate。Web は ALB の後ろの ECS サービス、バッチは同じイメージの RunTask（09） |
| イメージの置き場所 | ECR に 2 つのリポジトリ: Ruby のベースと、アプリ。ECR の拡張スキャン（Inspector）を有効にする |
| CPU の種類 | Dockerfile はどちらでも組める。arm64（Graviton）のほうが安い。手元の Mac も arm64 なので、arm64 で gem が組めてテストが通れば arm64 にする。古い gem に arm64 の配布物がない・組めない場合は amd64 にする。**ビルドとテストは実行環境と同じ種類で行う** |
| DB への接続 | mysql2 は MariaDB Connector/C（Debian の `libmariadb3`）で組む。trixie の `libmariadb3` には `caching_sha2_password` のプラグインが入っている。TLS で繋ぎ、`sslca` に RDS の CA を指定する |
| 秘密の値 | Secrets Manager か Parameter Store に置き、タスク定義の `secrets` で渡す |
| ログ | 標準出力 → CloudWatch Logs |

## 8. 更新の運用と、残るリスク

### 更新の運用

- **Ruby のベースイメージは定期的に作り直す**（例: 月 1 回と、Debian の重要なセキュリティ勧告が出たとき）。続けてアプリのイメージも作り直してデプロイしないと、動いているコンテナには反映されない。
- **スキャナーは Ruby 本体の脆弱性を検出できない**。ソースから組んだ Ruby は dpkg の管理外なので、Inspector が見るのは OS のパッケージと Gemfile.lock だけになる。Ruby 2.7 の脆弱性は、検出されなくても直っていない前提で扱う。

### 版の一覧（上げるときに直す場所）

| 部品 | 版 | 場所 |
|---|---|---|
| Debian | 13 trixie（slim） | `ruby-base/Dockerfile` の `DEBIAN_IMAGE`（運用では digest で固定する） |
| Ruby | 2.7.8 | `ruby-base/Dockerfile` の `RUBY_VERSION`・`RUBY_SHA256` |
| openssl 拡張 | openssl gem 3.3.3 | `ruby-base/Dockerfile` の `OPENSSL_GEM_VERSION`・`OPENSSL_GEM_SHA256`（3.3 系の更新が出たら上げる） |
| RubyGems / Bundler | 3.4.22 / 2.4.22 | `ruby-base/Dockerfile` の `RUBYGEMS_VERSION`・`BUNDLER_VERSION` |
| Ruby のベースのタグ | `2.7.8-trixie(-slim)` | `app/Dockerfile` の `RUBY_BUILD_IMAGE`・`RUBY_SLIM_IMAGE` |
| Node.js | Debian の nodejs（trixie は 20.19） | `app/Dockerfile`。execjs が使うだけなら Debian の版で足りる。webpacker などで新しい Node.js が要るなら、assets の段だけ公式の node のイメージから持ってくる |

### 残るリスク

- **Rails 5 と Ruby 2.7 にはセキュリティ修正が出ない**。2.7.8 のリリースノートにも、脆弱性が見つかっても 2.7.9 は出さないと書かれている。OS を新しくしても、ここは変わらない。
- 当面の対策（公開範囲の制限、WAF など）と、06 のバージョンアップの計画を合わせて進める。このイメージは、版を上げるまでのつなぎである。

## 9. 確かめ方（大きな取得があるため、Wi-Fi のあるところで行う）

初回の取得量の目安（実測していない）: `debian:trixie-slim` 約 30 MB、ビルド用の apt のパッケージ 100〜150 MB、Ruby のソース 12 MB、gem と Node.js などで数十 MB。**合計 200〜300 MB 程度**。

```bash
# 1. Ruby のベース（アプリがなくても確かめられる）
docker build --target build -t ruby27:2.7.8-trixie      docs/rr/ruby-base
docker build --target slim  -t ruby27:2.7.8-trixie-slim docs/rr/ruby-base
docker run --rm ruby27:2.7.8-trixie-slim ruby -ropenssl -e '
  puts RUBY_DESCRIPTION, OpenSSL::OPENSSL_LIBRARY_VERSION, OpenSSL::VERSION
  require "net/http"; puts Net::HTTP.get_response(URI("https://rubygems.org")).code'

# 2. アプリ（統合管理システムのリポジトリのルートで。app/Dockerfile と .dockerignore を置いてから）
docker build -t integrated-management:local .
docker run --rm integrated-management:local bin/rails runner 'puts Rails.version'
```

確かめること:

1. Ruby が GCC 14 で組めて、OpenSSL 3.5 を使っていること。
2. `bundle install` で全部の gem が組めること（組めない gem を一覧にする）。
3. テスト（あれば）がコンテナの中で通ること。
4. MySQL 8.4（手元の `mysql:8.4.11` のイメージで足りる）へ TLS と `caching_sha2_password` で繋げること。
