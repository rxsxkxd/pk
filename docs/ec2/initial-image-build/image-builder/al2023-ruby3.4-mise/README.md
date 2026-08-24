# EC2 Image Builder の定義: Amazon Linux 2023 と Ruby 3 系の最新（mise のビルド済みの Ruby。下書き・未検証・保留）

> 位置付け: [Docker の定義（mise のビルド済みの Ruby）](../../docker/al2023-ruby3.4-mise/README.md) と同じ入れ方で、土台の AMI を作る定義の**下書き**。**AWS へのデプロイも、CloudFormation の検証もしていない**。Docker の定義もまだ動かしていないため、**検証は保留**にしている。Docker の定義を動かして分かったこと（特に、ビルド済みの Ruby が OpenSSL などを同梱しているか）を、この定義に反映してから試す。
>
> 作成日: 2026-10-28

## ファイル

| ファイル | 内容 |
|---|---|
| `al2023-ruby-mise-base.yml` | CloudFormation のテンプレート。資源の組み立て（ロール、コンポーネント、レシピ、インフラストラクチャの設定、配布の設定、パイプライン）は [ruby-build の定義](../al2023-ruby3.4/README.md) と同じで、**コンポーネントの中身と、パラメーターと、定期実行の条件が違う** |

資源の説明、使い方、版の上げ方、共通の未確認の点は [ruby-build の定義の README](../al2023-ruby3.4/README.md) と同じなので、ここでは違いだけを書く。

## コンポーネントの手順

| ステップ | 内容 |
|---|---|
| `InstallMise` | mise の公式の dnf のリポジトリを足し、`dnf install mise-<バージョン>`（パラメーター `MiseVersion`、既定 `2026.10.21`） |
| `InstallBuildTools` | `gcc`、`make`（リリース用インスタンスでネイティブ拡張の gem をビルドするため）。開発用のライブラリ（`openssl-devel` など）は入れていない。要るかは、ビルド済みの Ruby がライブラリを同梱しているかと、アプリの gem による |
| `ConfigureEnvironment` | `/etc/profile.d/mise.sh` に、mise の置き場所（`/opt/mise`）、`MISE_RUBY_COMPILE=false`、shims の `PATH`、`LANG` を書く。`/etc/gemrc` |
| `InstallRuby` | `mise use --global ruby@<RubyVersion>`（既定 `3`）。全体の既定として `/opt/mise/config.toml` に書かれる。取得したアーカイブは消す |
| `validate` の段 | Ruby のバージョン（指定で始まるか）、`openssl`・`psych`・`zlib`・`fiddle`、YJIT、gem と bundle |
| `test` の段 | 新しいインスタンスのログインのシェルで、同じ確認と UTF-8、`mise ls` |

## ほかの定義との違い

| 項目 | この定義（mise） | ruby-build の定義 | AL2023 のパッケージの定義 |
|---|---|---|---|
| Ruby のバージョンの指定 | `RubyVersion`（既定 `3` で追従。`3.4.12` で固定） | `RubyVersion`（`3.4.12`） | `RubyPackageVersion`（`3.4.8`） |
| 置き場所 | `/opt/mise`（Docker の定義では `/mise`） | `/opt/ruby` | `/usr/bin` など |
| コマンドの通り道 | mise の shims（`/opt/mise/shims`） | `/opt/ruby/bin` | alternatives |
| 取得元 | mise のリポジトリと GitHub（jdx/ruby） | GitHub と cache.ruby-lang.org | AL2023 のリポジトリ |
| インスタンスタイプの既定 | `t3a.medium` | `c7a.large` | `t3a.medium` |
| 定期実行の条件の既定 | **式に合えば毎回作る**（`EXPRESSION_MATCH_ONLY`） | 親イメージなどの更新があるときだけ | 同左 |
| AMI のタグ | `RubyInstall=mise`、`RubyVersionSpec`（指定の値。入った版ではない） | `RubyVersion` | `RubyInstall=dnf-ruby3.4`、`RubyPackageVersion` |

置き場所を Docker の定義（`/mise`）と変えたのは、EC2 ではルートの直下に置く理由がないため。

## 3 系の最新への追従

`RubyVersion=3` のとき、パイプラインを実行するたびに、その時点の 3 系の最新の Ruby が入る。レシピの版を上げる必要はない（レシピの中身は `3` のまま変わらない）。

| 点 | 内容 |
|---|---|
| 定期実行の条件 | 新しい Ruby が出たことは、Image Builder の「依存の更新」として扱われない（**未確認**だが、Image Builder が知っているのは親イメージやコンポーネントの版だけのはず）。そのため既定は `EXPRESSION_MATCH_ONLY`（式に合えば毎回作る）にしている |
| どの Ruby が入ったか | AMI のタグ `RubyVersionSpec` は指定の値（`3`）で、入った版ではない。入った版は、ビルドのログ（`InstallRuby` の `mise ls`）か、インスタンスで `ruby -v` を見て確かめる。AMI のタグに入った版を残すには、別の仕組みが要る |
| アプリとのずれ | Docker の定義の README と同じ（アプリの `.ruby-version` をパッチバージョンまで書くと、土台とずれる） |

## アプリのユーザーから使うときの注意

`/opt/mise` は root の持ち物になる。アプリを別のユーザー（例: `webapp`）で動かす場合:

| 点 | 内容 |
|---|---|
| `ruby` や `bundle` を使う | ログインのシェルなら `/etc/profile.d/mise.sh` で使える。systemd のサービスでは、ユニットの `Environment=` に `PATH`（`/opt/mise/shims` を含む）と `MISE_DATA_DIR` などを書く |
| gem を入れる | `/opt/mise` の Ruby の中には書けない。`bundle config set path vendor/bundle` などで、アプリの側に入れる |
| mise のキャッシュ | `MISE_CACHE_DIR`（`/opt/mise/cache`）に書けないことで、警告や失敗が出ないか（**未確認**） |

## この定義に固有の未確認の点

[ruby-build の定義の未確認の点](../al2023-ruby3.4/README.md#未確認の点) の 1〜4、6〜9 に加えて、次の点がある。

| # | 点 |
|---|---|
| 1 | Docker の定義の「試して確かめたいこと」すべて（mise のリポジトリから入るか、ビルド済みの Ruby が使われるか、OpenSSL などを同梱しているか、証明書をどこから読むか、YJIT） |
| 2 | AWSTOE の `ExecuteBash` で、複数行のコマンド（`/etc/profile.d/mise.sh` を書くヒアドキュメント）がそのまま実行されるか |
| 3 | 新しい Ruby が、Image Builder の定期実行の条件で「依存の更新」として扱われないこと |
| 4 | アプリのユーザーから shims 経由で使うときに、mise が root の持ち物の `/opt/mise` に書こうとしないか |
| 5 | GitHub の artifact attestation の検証（`ruby.github_attestations`）が、ビルド用のインスタンスから GitHub の API に届いて通るか（API の回数の上限を含む） |

## 参考

- [Ruby - mise](https://mise.jdx.dev/lang/ruby.html)
- [jdx/ruby](https://github.com/jdx/ruby)
