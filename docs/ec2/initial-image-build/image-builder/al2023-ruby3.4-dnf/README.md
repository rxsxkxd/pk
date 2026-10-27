# EC2 Image Builder の定義: Amazon Linux 2023 と Ruby 3.4（AL2023 のパッケージ ruby3.4。下書き・未検証）

> 位置付け: [ruby-build でソースからビルドする定義](../al2023-ruby3.4/README.md) と比べるための、**AL2023 のパッケージ（`dnf install ruby3.4`）で Ruby を入れる**土台の AMI の定義の**下書き**。[土台の構成](../../base-image-composition.md) の Ruby の入れ方 A にあたる。**AWS へのデプロイも、CloudFormation の検証もしていない**。手順は [Docker の定義（AL2023 のパッケージ）](../../docker/al2023-ruby3.4-dnf/README.md) と揃えている。
>
> 作成日: 2026-10-28

## ファイル

| ファイル | 内容 |
|---|---|
| `al2023-ruby-dnf-base.yml` | CloudFormation のテンプレート。資源の組み立て（ロール、コンポーネント、レシピ、インフラストラクチャの設定、配布の設定、パイプライン）は ruby-build の定義と同じで、**コンポーネントの中身と、パラメーターが違う** |

資源の説明、使い方、版の上げ方、共通の未確認の点は [ruby-build の定義の README](../al2023-ruby3.4/README.md) と同じなので、ここでは違いだけを書く。

## ruby-build の定義との違い

| 項目 | この定義（AL2023 のパッケージ） | ruby-build の定義 |
|---|---|---|
| Ruby の入れ方 | `dnf install ruby3.4-<バージョン>` | ruby-build でソースからビルド |
| バージョンの指定 | パラメーター `RubyPackageVersion`（既定 `3.4.8`）。空なら、親イメージの AL2023 のリリースにある最新 | `RubyVersion`（既定 `3.4.12`）と `RubyBuildVersion` |
| ビルドに要るもの | コンパイルしない。Rust も要らない | `gcc` など、YJIT のための Rust（ビルドの後に外す） |
| インスタンスタイプの既定 | `t3a.medium` | `c7a.large`（コンパイルのため） |
| 取得元 | AL2023 のパッケージのリポジトリだけ（GitHub や cache.ruby-lang.org に出ない） | GitHub と cache.ruby-lang.org にも出る |
| コマンドの名前 | `ruby` / `gem` / `bundle` を alternatives で `ruby3.4` に向ける（ステップ `ConfigureAlternatives`） | `/opt/ruby/bin` を `PATH` に足す |
| 残すビルドの道具 | `gcc`、`make`、`ruby3.4-devel`、`*-devel`（ネイティブ拡張の gem のため） | `gcc`、`make`、`*-devel` |
| AMI の名前とタグ | `<NamePrefix>-<ビルドの日時>`。タグ `RubyInstall=dnf-ruby3.4`、`RubyPackageVersion`（空のときは `latest-in-release`） | `<NamePrefix>-ruby<RubyVersion>-<ビルドの日時>`。タグ `RubyVersion` |
| ビルド時の確認 | `ruby -v` のバージョン、`openssl`・`psych`・`zlib`、UTF-8。YJIT は表示だけ | 左に加えて `fiddle`、YJIT、Rust が残っていないこと |

## バージョンを指定するか、AL2023 に任せるか

この入れ方の利点は、**Ruby のセキュリティ更新が OS の更新（AL2023 の新しいリリース）で入る**ことである。バージョンを 3.4.8 に固定すると、その利点がなくなる。

| `RubyPackageVersion` | 入る Ruby | 向いている場面 | 注意 |
|---|---|---|---|
| `3.4.8`（既定） | 3.4.8 | アプリと手元・CodeBuild の Ruby をパッチバージョンまで揃えたいとき | 親イメージ（既定は最新の AL2023）のリポジトリから 3.4.8 が外れると、ビルドが失敗する。続けて使うなら、親イメージも固定する |
| 空 | 親イメージの AL2023 のリリースにある最新の 3.4 系 | 土台の作り直し（更新のサイクルの C3）で、Ruby の修正も取り込みたいとき | パッチバージョンが土台ごとに変わる。アプリの `.ruby-version` を `3.4` のようにパッチバージョンまで書かない形にするか、土台に合わせて直す |

土台の構成では、バージョンが確定し、パッチバージョンを OS に任せてよいと決まったら、入れ方 A に切り替える余地がある、としていた。その場合は **空（AL2023 に任せる）** が本来の使い方になる。

## この定義に固有の未確認の点

[ruby-build の定義の未確認の点](../al2023-ruby3.4/README.md#未確認の点) の 1〜4、6〜9 に加えて、次の点がある（Docker の定義の未確認の点と重なる）。

| # | 点 |
|---|---|
| 1 | `dnf install ruby3.4-3.4.8` の形で、バージョンを指定して入れられるか |
| 2 | `alternatives --set ruby /usr/bin/ruby3.4` が通るか。ステップの中で `ruby` の alternatives がまだない場合の扱い |
| 3 | `ruby3.4-<道具>` の実際の名前（ユーザーガイドには `ruby3.4-bundle` と `ruby3.4-bundler` の両方が出てくる） |
| 4 | ネイティブ拡張の gem のビルドに、`ruby3.4-devel` と `gcc`・`make` のほかに要るパッケージがあるか |
| 5 | ルートで `gem install` したとき、`bundle install` したときの gem の置き場所 |
| 6 | YJIT が組み込まれているか |

## 参考

- [Ruby in AL2023](https://docs.aws.amazon.com/linux/al2023/ug/ruby.html)（版付きのパッケージ、alternatives での切り替え、道具の登録）
