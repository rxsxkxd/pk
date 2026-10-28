# Docker の定義: Amazon Linux 2023 と Ruby 3 系の最新（mise のビルド済みの Ruby。試すためのもの・未検証）

> 位置付け: Ruby の入れ方の 3 つ目の候補として、**mise でビルド済みの Ruby（バイナリ）を取得する**方法を試すための定義。土台のイメージは [AL2023 のパッケージの定義](../al2023-ruby3.4-dnf/README.md) と同じリリースに digest で固定している。**まだビルドしていない**。
>
> 作成日: 2026-10-28

## 3 つの入れ方

| 入れ方 | 定義 | Ruby | 取得するもの | コンパイル |
|---|---|---|---|---|
| ruby-build | [al2023-ruby3.4](../al2023-ruby3.4/README.md) | 3.4.12 | Ruby のソース | する（約 1 分。YJIT のために Rust も要る） |
| AL2023 のパッケージ | [al2023-ruby3.4-dnf](../al2023-ruby3.4-dnf/README.md) | 3.4.8（AL2023 のリリースで決まる） | AL2023 のパッケージ | しない |
| **mise のビルド済みの Ruby** | この定義 | 3 系の最新（2026-10-28 時点で 3.4.12）に追従 | mise のパッケージと、[jdx/ruby](https://github.com/jdx/ruby) のビルド済みの Ruby（約 90 MB） | しない |

## 定義の中身

| 手順 | 内容 |
|---|---|
| mise を入れる | mise の公式の dnf のリポジトリ（`https://mise.jdx.dev/rpm/mise.repo`）を足して `dnf install mise-<バージョン>`。Ubuntu の `extrepo enable mise` と `apt install mise` に当たる（AL2023 には extrepo がない）。バージョンはビルドの引数 `MISE_VERSION`（既定 `2026.10.21`） |
| mise の置き場所 | `MISE_DATA_DIR`・`MISE_CONFIG_DIR`・`MISE_CACHE_DIR` を `/mise` の下にまとめ、`/mise/shims` を `PATH` に足す（mise の Docker の手引きと同じ形） |
| Ruby を入れる | `mise use --global ruby@3`（ビルドの引数 `RUBY_VERSION`、既定 `3`）。全体の既定として `/mise/config.toml` に `ruby = "3"` と書かれ、**作り直すたびに、その時点の 3 系の最新が入る**。Ruby 3.4 の次は 4.0 なので、3 系の最新は 3.4 系の最新のパッチバージョンになる。決まったバージョンにするときは `RUBY_VERSION=3.4.12` のように指定する |
| コンパイルさせない | `MISE_RUBY_COMPILE=false`。ビルド済みの Ruby が見つからないときに、黙ってコンパイルに切り替わらず、失敗する |
| 試すための表示 | mise と Ruby の置き場所、OpenSSL のビルド時と実行時のバージョン、既定の証明書のファイル、`ldd` による `ruby` と拡張ライブラリ（openssl・psych・zlib・fiddle）の依存先。失敗にはしない |
| ビルド時の確認 | Ruby のバージョン（`RUBY_VERSION` で始まるか。既定なら `ruby 3.` で始まるか）、`openssl`・`psych`・`zlib`・`fiddle`、UTF-8、YJIT、gem と bundle。満たさなければビルドが失敗する |

## 使い方

このフォルダで実行する。取得するのは、mise のリポジトリのメタデータと mise のパッケージ、AL2023 のリポジトリのメタデータ（約 85 MB）、ビルド済みの Ruby（約 90 MB）。土台のイメージは手元にあるもの。

```bash
docker build --progress=plain -t al2023-ruby:3-mise . 2>&1 | tee build.log
docker run --rm al2023-ruby:3-mise
docker run --rm al2023-ruby:3-mise ruby --yjit -v
docker run --rm al2023-ruby:3-mise mise ls

# 新しい Ruby に追従させる（ビルドのキャッシュが残っていると、Ruby を入れる手順が実行し直されない）
docker build --no-cache -t al2023-ruby:3-mise .

# 決まったバージョンにする
docker build --build-arg RUBY_VERSION=3.4.12 -t al2023-ruby:3.4.12-mise .
```

追従のしかたの注意:

| 点 | 内容 |
|---|---|
| ビルドのキャッシュ | Docker は、手順の文字列が変わらなければキャッシュを使う。`ruby@3` のままだと、新しい Ruby が出ても、キャッシュがある限り古い Ruby のまま。追従させるときは `--no-cache` で作り直す |
| 同じ定義から違う Ruby | 作った時期によって、同じ定義から違うパッチバージョンの Ruby のイメージができる。どの Ruby が入ったかは、`ruby -v` か `mise ls` で確かめる（土台に使うなら、AMI のタグなどに残す） |
| アプリとのずれ | アプリの `.ruby-version` がパッチバージョンまで書かれていると、土台の Ruby とずれる。追従させるなら、アプリ側も `3.4` のように書くか、mise の設定（`mise.toml`）で揃える |

## 試して確かめたいこと

| # | 確かめること | 見るところ |
|---|---|---|
| 1 | AL2023 の上で、mise のリポジトリから mise が入るか（arm64 のパッケージがあるか、GPG の鍵の取り込み） | `dnf install` の出力 |
| 2 | ビルド済みの Ruby が使われるか（コンパイルされないか） | `mise use` の出力。コンパイルに要る `gcc` などは入れていないので、コンパイルしようとすれば失敗する |
| 3 | **OpenSSL や libyaml を OS のものを使うか、同梱のものを使うか** | 試すための表示の、OpenSSL の実行時のバージョンと `ldd` の出力。同梱なら、**OS の OpenSSL の更新が Ruby に効かず**、Ruby を入れ直すまで直らない（Go と同じ扱いになる） |
| 4 | 証明書をどこから読むか | 既定の証明書のファイル。jdx/ruby は、`SSL_CERT_FILE` などの指定、OS の証明書、同梱の証明書の順に探すとしている |
| 5 | YJIT が入っているか | ビルド時の確認。jdx/ruby には YJIT ありとなし（`no_yjit`）の 2 種類がある |
| 6 | イメージの大きさとビルドの時間 | ほかの 2 つの定義（396 MB / 309 MB）と比べる |
| 7 | shims（`/mise/shims/ruby`）経由での起動の速さ | `ruby -v` を何度か実行して比べる |

結果は、この README に「動かして分かったこと」として書き足す。

## 土台に使うときに考えること（試した後に）

| 項目 | 内容 |
|---|---|
| 取得元 | 実行時に GitHub（jdx/ruby）と mise のリポジトリに出る。Image Builder で使うなら、インターネットに出られるサブネットが要る |
| セキュリティ更新 | Ruby の修正は、mise で新しいバージョンを入れ直して取り込む（ruby-build と同じ）。OpenSSL などを同梱しているなら、その修正もビルド済みの Ruby の更新を待つことになる |
| 信頼 | ビルド済みの Ruby は、mise の作者が管理する jdx/ruby が作ったもの。GitHub の artifact attestation での検証がある（`ruby.github_attestations`） |
| アプリの `.ruby-version` / `mise.toml` | 手元や CodeBuild でも mise を使うなら、同じ設定のファイルで揃えられる |

## 参考

- [Ruby - mise](https://mise.jdx.dev/lang/ruby.html)（ビルド済みの Ruby、`ruby.compile`）
- [Docker - mise cookbook](https://mise.jdx.dev/mise-cookbook/docker.html)
- [jdx/ruby](https://github.com/jdx/ruby)
