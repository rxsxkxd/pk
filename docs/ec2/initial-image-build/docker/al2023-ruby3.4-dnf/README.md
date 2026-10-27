# Docker の定義: Amazon Linux 2023 と Ruby 3.4（AL2023 のパッケージ ruby3.4。未検証）

> 位置付け: [ruby-build で最新のパッチバージョンを入れる定義](../al2023-ruby3.4/README.md) と比べるための、**AL2023 のパッケージ（`dnf install ruby3.4`）で Ruby を入れる**定義。[土台の構成](../../base-image-composition.md) の Ruby の入れ方 A にあたる。**ビルドしての確認はしていない**。
>
> 同じ入れ方の EC2 Image Builder の定義: [EC2 Image Builder の定義（AL2023 のパッケージ ruby3.4）](../../image-builder/al2023-ruby3.4-dnf/README.md)
>
> 作成日: 2026-10-28

## 入る Ruby

AL2023 のコンテナイメージ `2023.12.20261026` では、`ruby3.4` のパッケージは **3.4.8**（`3.4.8-27.amzn2023.0.7`）だった（2026-10-28 に dnf のパッケージの一覧で確認。インストールはしていない）。この定義は、ビルドの引数 `RUBY_PACKAGE_VERSION`（既定 `3.4.8`）でバージョンを指定して入れる。

パッケージのリポジトリは AL2023 のリリースに固定されているため、入れられるバージョンは土台のイメージの AL2023 のリリースで決まる。新しいリリースのイメージで、3.4.8 がリポジトリから外れていれば、指定したバージョンが見つからずにビルドが失敗する。

## ruby-build の定義との違い

| 項目 | この定義（AL2023 のパッケージ） | ruby-build の定義 |
|---|---|---|
| Ruby のバージョン | AL2023 のリリースにあるもの（3.4.8） | 指定したもの（3.4.12） |
| ビルドの時間 | 短い（コンパイルしない） | 長い（Ruby と、YJIT のための Rust） |
| 段の分け方 | 1 段 | 2 段（ビルドの段と実行の段） |
| Ruby のセキュリティ更新 | **OS の更新（AL2023 の新しいリリース）で入る** | Ruby のバージョンを上げてビルドし直す |
| コマンドの名前 | 本体は版付き（`ruby3.4`、`ruby3.4-gem`、`ruby3.4-bundle` など）。`ruby` / `gem` / `bundle` は alternatives で向ける | `ruby` / `gem` / `bundle` |
| 置き場所 | `/usr/bin` など（OS のパッケージの置き場所） | `/opt/ruby` |
| YJIT | 組み込まれているかは**未確認**（ビルドの最後に表示するだけで、失敗にはしない） | 組み込む |

## 定義の中身

| 手順 | 内容 |
|---|---|
| Ruby を入れる | `dnf install ruby3.4-<バージョン>`。gem（`ruby3.4-rubygems`）と bundle（`ruby3.4-rubygem-bundler`）は依存として入る |
| 版の付かない名前を向ける | `alternatives --set ruby /usr/bin/ruby3.4` で `ruby` を向ける。AL2023 のユーザーガイドによると、`gem` や `bundle` などは入れただけでは alternatives に登録されないことがあるため、`/usr/bin/<道具>` がなければ `alternatives --install` で登録する |
| 文字コード | `LANG=C.UTF-8` |
| gem のドキュメント | 入れない（`/etc/gemrc`） |
| ビルド時の確認 | Ruby のバージョンが指定どおりか、`openssl`・`psych`・`zlib` が読めるか、既定のエンコーディングが UTF-8 か。YJIT と gem・bundle のバージョンは表示する |

## 使い方（想定）

このフォルダで実行する。

```bash
docker build -t al2023-ruby:3.4.8-dnf .
docker run --rm al2023-ruby:3.4.8-dnf

# AL2023 のリリースにある最新の ruby3.4 を入れる（バージョンを指定しない）
docker build --build-arg RUBY_PACKAGE_VERSION= -t al2023-ruby:3.4-dnf .
```

## 未確認の点

| # | 点 |
|---|---|
| 1 | `dnf install ruby3.4-3.4.8` の形で、バージョンを指定して入れられるか |
| 2 | `alternatives --set ruby /usr/bin/ruby3.4` が、ruby3.4 だけを入れた状態で通るか（自動の設定のままで既に ruby3.4 を向いているはず） |
| 3 | `ruby3.4-<道具>` の実際の名前（ユーザーガイドには `ruby3.4-bundle` と `ruby3.4-bundler` の両方が出てくる）と、ルートで `gem install` したときの gem の置き場所 |
| 4 | `fiddle` などの、パッケージが分かれている可能性のある標準のライブラリ（この定義では確認の対象から外している） |
| 5 | YJIT が組み込まれているか |
| 6 | 同梱の Bundler のバージョン |

## この定義に入れていないもの

ruby-build の定義と同じ（アプリと gem、ネイティブ拡張の gem のビルドに要るもの、一般ユーザー）。ネイティブ拡張の gem をビルドするときは、`gcc`、`make`、`ruby3.4-devel` などが要る（AL2023 で、ほかに要るパッケージがあるかは**未確認**）。
