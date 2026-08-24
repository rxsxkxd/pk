# EC2 Image Builder の定義: Amazon Linux 2023 と Ruby 3.4（AL2023 のパッケージ ruby3.4。下書き・未検証）

> 位置付け: [ruby-build でソースからビルドする定義](../al2023-ruby3.4/README.md) と比べるための、**AL2023 のパッケージ（`dnf install ruby3.4`）で Ruby を入れる**土台の AMI の定義の**下書き**。[土台の構成](../../base-image-composition.md) の Ruby の入れ方 A にあたる。**AWS へのデプロイも、CloudFormation の検証もしていない**。手順は [Docker の定義（AL2023 のパッケージ）](../../docker/al2023-ruby3.4-dnf/README.md) と揃えていて、コンポーネントの手順のうち Ruby の入れ方と alternatives の設定は、Docker の定義で動くことを確かめた（arm64、AL2023 2023.12.20261026。[動かして分かったこと](../../docker/al2023-ruby3.4-dnf/README.md#動かして分かったこと)）。
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
| コマンドの名前 | `ruby` はパッケージが alternatives に登録する。`gem` / `bundle` などは登録されないため、`ruby` の従属のリンクとして足す（ステップ `ConfigureAlternatives`） | `/opt/ruby/bin` を `PATH` に足す |
| 残すビルドの道具 | `gcc`、`make`、`ruby3.4-devel`、`*-devel`（ネイティブ拡張の gem のため） | `gcc`、`make`、`*-devel` |
| AMI の名前とタグ | `<NamePrefix>-<ビルドの日時>`。タグ `RubyInstall=dnf-ruby3.4`、`RubyPackageVersion`（空のときは `latest-in-release`） | `<NamePrefix>-ruby<RubyVersion>-<ビルドの日時>`。タグ `RubyVersion` |
| ビルド時の確認 | `ruby -v` のバージョン、`openssl`・`psych`・`zlib`・`fiddle`、YJIT、UTF-8 | 左に加えて、Rust が残っていないこと |

## バージョンを指定するか、AL2023 に任せるか

この入れ方の利点は、**Ruby のセキュリティ更新が OS の更新（AL2023 の新しいリリース）で入る**ことである。バージョンを 3.4.8 に固定すると、その利点がなくなる。

| `RubyPackageVersion` | 入る Ruby | 向いている場面 | 注意 |
|---|---|---|---|
| `3.4.8`（既定） | 3.4.8 | アプリと手元・CodeBuild の Ruby をパッチバージョンまで揃えたいとき | 親イメージ（既定は最新の AL2023）のリポジトリから 3.4.8 が外れると、ビルドが失敗する。続けて使うなら、親イメージも固定する（パラメーター `ParentImage` に、3.4.8 を含む AL2023 のリリースのイメージを指定する。Docker の定義では、コンテナイメージを digest で固定している） |
| 空 | 親イメージの AL2023 のリリースにある最新の 3.4 系 | 土台の作り直し（更新のサイクルの C3）で、Ruby の修正も取り込みたいとき | パッチバージョンが土台ごとに変わる。アプリの `.ruby-version` を `3.4` のようにパッチバージョンまで書かない形にするか、土台に合わせて直す |

土台の構成では、バージョンが確定し、パッチバージョンを OS に任せてよいと決まったら、入れ方 A に切り替える余地がある、としていた。その場合は **空（AL2023 に任せる）** が本来の使い方になる。

## この定義に固有の未確認の点

[ruby-build の定義の未確認の点](../al2023-ruby3.4/README.md#未確認の点) の 1〜4、6〜9 に加えて、次の点がある（Docker の定義の未確認の点と重なる）。

| # | 点 |
|---|---|
| 1 | EC2（x86_64 の AL2023 の AMI）でも、Docker の定義と同じく `gem` などの従属のリンクが登録されないか（この定義は、登録されていれば何もしないので、どちらでも動く） |
| 2 | `ruby3.4-devel` が、指定したバージョンの `ruby3.4` と同じバージョンで入るか（`ruby3.4-devel` はバージョンを指定していない。親イメージのリポジトリに複数のバージョンがあると、ずれる可能性がある） |
| 3 | ネイティブ拡張の gem のビルドに、`ruby3.4-devel` と `gcc`・`make` のほかに要るパッケージがあるか |

Docker の定義で確かめたこと（バージョンを指定したインストール、道具の名前、gem の置き場所、YJIT が組み込まれていること）は、[Docker の定義の README](../../docker/al2023-ruby3.4-dnf/README.md#動かして分かったこと) を参照。

## 参考

- [Ruby in AL2023](https://docs.aws.amazon.com/linux/al2023/ug/ruby.html)（版付きのパッケージ、alternatives での切り替え、道具の登録）
