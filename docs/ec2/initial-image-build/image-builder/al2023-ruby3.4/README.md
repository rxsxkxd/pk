# EC2 Image Builder の定義: Amazon Linux 2023 と Ruby 3.4（下書き・未検証）

> 位置付け: 起点の方式の候補のうち「EC2 Image Builder」で、土台（層 0 の AL2023 に層 1 の下回りの Ruby を足したもの）の AMI を作る定義の**下書き**。**AWS へのデプロイも、CloudFormation の検証（cfn-lint など）もしていない**。手順は [Docker の定義](../../docker/al2023-ruby3.4/README.md) と揃えている（Docker の定義は手元でビルドを確認済み）。
>
> 関連: [土台の構成](../../base-image-composition.md)（層の分け方と Ruby の入れ方）、[EC2 Image Builder の仕組み](../../ec2-image-builder-how-it-works.md)、[更新のサイクル](../../update-cycles.md)（C3 の土台の作り直し）
>
> 作成日: 2026-10-28

比べるための、AL2023 のパッケージ（`ruby3.4`）で入れる定義は [EC2 Image Builder の定義（AL2023 のパッケージ）](../al2023-ruby3.4-dnf/README.md)。

## ファイル

| ファイル | 内容 |
|---|---|
| `al2023-ruby-base.yml` | CloudFormation のテンプレート。インスタンスのロール、コンポーネント、イメージのレシピ、インフラストラクチャの設定、配布の設定、イメージのパイプラインを 1 つのスタックで作る。コンポーネントの定義（AWSTOE の YAML）は、テンプレートの中に埋め込んでいる |

今は手書きの下書きである。採用が決まったら、中段の AMI 公開パイプラインと同じく Go の生成ツールで生成する形（`generated/` と `--check`）に移すことを考える。

## Docker の定義との対応

| Docker の定義 | この定義 |
|---|---|
| `FROM amazonlinux:2023` | イメージのレシピの親イメージ。既定は AWS が管理する最新の AL2023（x86_64）のイメージ（`amazon-linux-2023-x86/x.x.x`）。パラメーター `ParentImage` で AMI の ID などに変えられる |
| `ARG RUBY_VERSION` / `RUBY_BUILD_VERSION` | コンポーネントのパラメーター。値はスタックのパラメーター `RubyVersion` / `RubyBuildVersion` からレシピで渡す |
| ビルドの段の `RUN` | コンポーネントの `build` の段 |
| 最後の確認の `RUN` | `validate` の段（スナップショットを撮る前に、ビルド用のインスタンスで確かめる）と `test` の段（できた AMI から起動したテスト用のインスタンスで確かめる） |
| 2 つの段に分けたビルド | **分けない**（1 台のディスクがそのまま AMI になる）。下の「Docker と違う点」 |
| `ENV PATH` / `LANG` | `/etc/profile.d/ruby.sh` に書く |
| `/etc/gemrc` | 同じ |
| arm64 の Mac でのビルド | x86_64 のインスタンス（既定 `c7a.large`）でビルドする |

## Docker と違う点

| 項目 | 内容 |
|---|---|
| コンパイラーと開発用のライブラリを残す | リリース用インスタンスで `bundle install` を行い、ネイティブ拡張の gem をビルドするため、`gcc` や `*-devel` は層 1 に残す。外すのは、YJIT を組み込むためだけに使う **Rust だけ**（ステップ `RemoveRust`。`test` の段で入っていないことを確かめる） |
| ruby-build は残さない | ビルドの後に消す（Docker の定義では `/usr/local` に入れたまま） |
| rbenv は使わない | 1 つの AMI に入る Ruby は 1 つで、バージョンを変えるときは土台を作り直すため。ruby-build だけで `/opt/ruby` に入れる。[土台の構成](../../base-image-composition.md) の Ruby の入れ方 B（rbenv と ruby-build）は、採用するならこの形に直す |
| `LANG` は上書きしない | `/etc/profile.d/ruby.sh` では、`LANG` が空のときだけ `C.UTF-8` にする |
| systemd のサービス | `/etc/profile.d/` を読まない。アプリのサービスでは、ユニットの `Environment=` に `PATH` と `LANG` を書く（上物の側で扱う） |
| コマンドの失敗の扱い | 各ステップの先頭で `set -euo pipefail` にして、途中のコマンドの失敗でステップを失敗させる |

## 作られるもの

| 資源 | 名前 | 内容 |
|---|---|---|
| IAM ロールとインスタンスプロファイル | 自動 | `AmazonSSMManagedInstanceCore` と `EC2InstanceProfileForImageBuilder`。`LogBucketName` を指定したときは、ログの書き込み（`s3:PutObject`）も許可する |
| コンポーネント | `<NamePrefix>-ruby-from-source` | 版は `ComponentVersion` |
| イメージのレシピ | `<NamePrefix>` | 版は `RecipeVersion`。SSM Agent はビルドの後も残す |
| インフラストラクチャの設定 | `<NamePrefix>` | インスタンスタイプ、サブネット、セキュリティグループ、IMDSv2 の必須化、失敗時のインスタンスの削除、ログの置き場所 |
| 配布の設定 | `<NamePrefix>` | 同じリージョンに AMI を作る。名前は `<NamePrefix>-ruby<RubyVersion>-<ビルドの日時>`。タグは `Layer=base`、`RubyVersion`、`RecipeVersion` |
| イメージのパイプライン | `<NamePrefix>` | テストを行う（上限 60 分）。`ScheduleExpression` を指定したときだけ定期実行し、親イメージに更新があるときだけ作る |

## 使い方（想定）

前提:

- インターネットに出られるサブネット（NAT ゲートウェイなど）。GitHub（ruby-build）と cache.ruby-lang.org（Ruby のソース）から取得するため
- 受信なし、送信は TCP 443 だけのセキュリティグループ

```bash
# スタックの作成・更新
aws cloudformation deploy \
  --stack-name myapp-base-image-builder \
  --template-file al2023-ruby-base.yml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    NamePrefix=myapp-base \
    SubnetId=<サブネットの ID> \
    SecurityGroupId=<セキュリティグループの ID>

# 手動で土台を作る
aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn <スタックの出力 ImagePipelineArn>

# 進み具合と、できた AMI の確認
aws imagebuilder list-image-pipeline-images \
  --image-pipeline-arn <スタックの出力 ImagePipelineArn>
```

## 版の上げ方

Image Builder のコンポーネントとレシピは、**同じ名前と版のまま中身を変えられない**。CloudFormation でも、プロパティを変えると作り直しになり、同じ版のままだと名前と版がぶつかって失敗する（想定）。

| 変えるもの | 上げる版 |
|---|---|
| コンポーネントの中身（テンプレートの `Data`） | `ComponentVersion` と `RecipeVersion` |
| Ruby のバージョン（`RubyVersion` / `RubyBuildVersion`） | `RecipeVersion`（コンポーネントへ渡す値はレシピに含まれるため） |
| 親イメージ（`ParentImage`） | `RecipeVersion` |
| インスタンスタイプ、サブネット、ログの置き場所、定期実行 | 不要（レシピではないため） |

AWS が新しい AL2023 を出したときは、版を上げなくてよい。親イメージの既定（`x.x.x`）は、パイプラインを実行したときの最新の AL2023 を使う。

```bash
# 例: Ruby を上げる
aws cloudformation deploy ... --parameter-overrides \
  RubyVersion=3.4.13 RubyBuildVersion=<対応したリリース> RecipeVersion=1.0.1
```

## 未確認の点

確かめてから使う。

| # | 点 | 確かめ方 |
|---|---|---|
| 1 | AWS が管理する AL2023 のイメージの名前（`amazon-linux-2023-x86`）と、`x.x.x` で最新を指す書き方 | `aws imagebuilder list-images --owner Amazon` |
| 2 | 親イメージに SSM のパラメーター（`/aws/service/ami-amazon-linux-latest/...`）を指定できるか | Image Builder の文書。できるなら `ParentImage` の既定の候補になる |
| 3 | 定期実行の条件 `EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE` が、親イメージの `x.x.x` の更新を「依存の更新」と見なすか | Image Builder の文書 |
| 4 | AWSTOE の `ExecuteBash` で、`commands` の各行が 1 つのスクリプトとして続けて実行されるか（`set -euo pipefail` が後の行に効くか） | AWSTOE の文書。効かないなら、1 つのステップのコマンドを 1 行のスクリプトにまとめる |
| 5 | `dnf remove -y rust` で、Rust と一緒に入った依存（`rust-std-static` など）も外れるか。`gcc` が外れないか | 実機での確認 |
| 6 | `test` の段で、`bash -lc` によって `/etc/profile.d/ruby.sh` が読まれるか（SSM から実行したときのシェルの環境） | 実機での確認 |
| 7 | コンポーネントとレシピのプロパティを変えたときに、CloudFormation が作り直しとして扱い、版を上げれば成功するか | 実機での確認 |
| 8 | 1 回の実行にかかる時間と費用（ビルド用・テスト用のインスタンス、EBS、スナップショット） | 実機での確認 |
| 9 | AL2023 のパッケージのリポジトリに、S3 のゲートウェイエンドポイントだけで届くか（インターネットに出ないサブネットでビルドする場合） | AL2023 の文書 |

## 今後の検討

| 項目 | 内容 |
|---|---|
| 手順の共有 | インストールの手順を 1 本のシェルスクリプトにまとめ、Docker の定義（手元での確認用）と、このコンポーネントの両方から使う。手順がずれるのを防ぐ |
| 取得元 | ruby-build と Ruby の tar.gz を S3 に置き、SHA-256 を固定して、そこから取る（インターネットに出ないビルド、取得元が落ちていても作り直せる）。今は ruby-build の tar.gz 自体のチェックサムを確かめていない（Docker の定義も同じ） |
| 層 1 のほかのもの | アプリ用のユーザーとディレクトリ、gem が使うライブラリ（データベースのクライアントなど）、CloudWatch エージェント（AWS が管理するコンポーネントがある）、logrotate の設定。[運用中のメンテナンス](../../../notes/instance-provisioning/distributed-instance-maintenance.md#土台に入れておくと手当てが要らなくなるもの)の「土台に入れておくと手当てが要らなくなるもの」 |
| ディスクの大きさ | 親イメージの既定（AL2023 は 8 GB）のまま。アプリと gem を入れる余地を見て、レシピの `BlockDeviceMappings` で決める |
| アーキテクチャ | x86_64 だけ。Graviton（arm64）を使うなら、親イメージとインスタンスタイプを変えた別のレシピが要る |
| 古い AMI の片付け | Image Builder のライフサイクルのポリシーで整理できる |
| 生成への移行 | Go の生成ツールでこのテンプレートを生成する |
