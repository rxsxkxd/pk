# 未確認の一覧

[DESIGN.md](DESIGN.md) の設計で、まだ確かめていないこと。確かめたら結果を書いて消す。

## ビルド（手元で確かめられる。Wi-Fi のあるところで）

| # | 確かめること | 確かめ方 | だめだったとき |
|---|---|---|---|
| B1 | Ruby 2.7.8 が trixie の GCC 14 と `-fpermissive` で組めるか | `ruby-base` の `build` をビルドする | エラーの出たところの警告を個別に戻すか、bookworm に戻す（DESIGN.md の 3 章） |
| B2 | openssl gem 3.3.3 の拡張が、Ruby 2.7 のソースの中で組めるか。OpenSSL 3.5 で動くか | 同上。`ruby -ropenssl` と、rubygems.org への HTTPS 接続 | 3.3 系の別の版を試す。だめなら Ruby のソースに当てるパッチを用意する |
| B3 | `slim` で共有ライブラリが足りているか | `slim` のビルドの中の `ldd` の確認 | 足りないパッケージを `slim` に足す |
| B4 | パッケージ名が trixie で合っているか（`libssl3t64`・`libffi8`・`libgmp10`・`libyaml-0-2`・`libmariadb3`） | ビルドが通るか | `apt-cache search` で正しい名前を探す |

## アプリ（統合管理システムのリポジトリを見て確かめる）

| # | 確かめること | 見る場所 | 影響 |
|---|---|---|---|
| A1 | Rails 5 のマイナー版（5.0 / 5.1 / 5.2） | Gemfile.lock の `rails` | 5.0 / 5.1 なら Bundler を 1.17.3 にする |
| A2 | Gemfile.lock の `BUNDLED WITH` | Gemfile.lock の末尾 | `BUNDLER_VERSION` を合わせる |
| A3 | ネイティブ拡張を持つ gem とその版（mysql2・nokogiri・puma・ffi・eventmachine・sassc・bcrypt など） | Gemfile.lock | GCC 14 や OpenSSL 3 で組めない古い版は、上げる必要がある |
| A4 | `therubyracer` / `libv8` / `mini_racer` を使っているか | Gemfile | 新しい OS では組めない見込み。Node.js（execjs）に置き換える |
| A5 | OpenSSL を直接使うコードと、影響しうる gem（jwt・ruby-saml・net-ssh・omniauth 系など）の版 | `grep -rn 'OpenSSL::' app lib config`、Gemfile.lock | openssl gem 3.x の `PKey` が変更不可になった件などで動かなくなる |
| A6 | 外部への HTTPS 接続先が、OpenSSL 3 の既定のセキュリティレベルで繋がるか（古い TLS・弱い鍵） | 接続先の一覧 | 繋がらない先は、相手の対応を待つか、その接続だけ設定を緩める |
| A7 | webpacker（yarn）を使っているか。Node.js の版の指定 | Gemfile、`package.json`、`.node-version` | 使っていれば assets の段に yarn と新しい Node.js が要る |
| A8 | `assets:precompile` が DB や credentials なしで通るか | 手元でビルドする | 通らなければ、初期化処理を直すか、ビルド時だけダミーの `DATABASE_URL` を渡す |
| A9 | Git の URL で指定した gem があるか | Gemfile | ベースの `build` に git を入れてある。社内のリポジトリなら認証の渡し方を決める |
| A10 | 書き込む場所（`tmp`・`log` 以外。Active Storage の `storage` など） | `config/` | `rails` ユーザーが書けるようにする |
| A11 | `config/puma.rb` があるか。ポートと、スレッド数・ワーカー数 | `config/puma.rb` | なければ用意する |
| A12 | `mysql` コマンド（`default-mysql-client`）を使っているか | バッチ・スクリプト | 使っていなければ実行用イメージから外す |

## AWS 上でしか確かめられないこと

| # | 確かめること |
|---|---|
| W1 | RDS for MySQL 8.4 へ、mysql2（MariaDB Connector/C）から TLS と `caching_sha2_password` で繋がるか。`sslca`・`ssl_mode` の指定が効くか |
| W2 | Fargate の arm64 で、Web とバッチが amd64 と同じに動くか |
| W3 | ECR のスキャンで、ソースから組んだ Ruby が検出の対象外になっていることを確かめ、運用でどう補うかを決める |
