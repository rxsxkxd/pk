# AMI 公開パイプラインの仕組みの CDK 版（Go・Python）

仕組みの生成ツール（`cmd/generate-definitions`）が作る 4 つのスタックを、AWS CDK の L2 の構成要素で定義したもの。Go 版（`go/`）と Python 版（`python/`）の 2 つがあり、内容は同じ。

> 状態（2026-11-12）:
> - **Python 版**: 合成とテストを済ませた。`aws-cdk-lib` 2.275.0 で合成でき、合成時の検証の警告はない。cfn-lint（`tls-termination-migration/cdk/python/.venv` のもの）も警告なしで通る。生成ツールのテストが守っている約束を、`python/tests/` のテスト（CDK の assertions）で確かめている。AWS へのデプロイはまだしていない
> - **Go 版**: 骨組み（未実行）。CDK のライブラリ（`awscdk` 約 84 MB）をまだ取得していないので、合成も型の確認もしていない。確かめたのは構文（`gofmt`）だけ。Python 版の合成で見つかった誤り（起動テンプレートのセキュリティグループ）と同じ書き方が残っている（「次の段階」を参照）

## 位置づけ

| 項目 | 内容 |
|---|---|
| 正本 | 仕組みの生成ツール（`internal/definitions/`）のまま。CDK 版は並べて置く別の書き方 |
| 書き方 | L2（`iam.Role`、`ec2.LaunchTemplate`、`codepipeline.Pipeline` など）。L2 がない SSM ドキュメントだけ L1（`CfnDocument`） |
| 既存の環境との互換 | **ない**。L2 では論理 ID が生成ツールの出力と変わる（例: `LaunchTemplate` → `LaunchTemplateXXXXXXXX`）。生成ツールでデプロイ済みのスタックをこのテンプレートで更新すると、起動テンプレートなどが作り直しになり、参照中の Export が変わるので失敗する。**新しい環境向け** |
| 変えないもの | スタック名・リソースの名前・Export の名前・パイプラインのスタックの出力（命名規則どおり）。AMI 公開ツール（Ruby）と buildspec は、CDK 版でもそのまま動く |
| デプロイ | CDK はテンプレートを作る（`cdk synth`）ためだけに使う。デプロイは今までどおり担当者が AWS CLI で変更セットを作り、確認してから反映する（決定事項 D9）。`cdk bootstrap` は不要（ブートストラップのバージョンの確認を入れない設定にしている） |
| 言語の方針 | Go 版は決定事項 D10（作業者の PC の道具は Go）の範囲。Python 版はこの方針の外で、比べるための見本という扱い（正式に使うかは未決） |

## 構成

```
cdk/
  go/                                    Go 版（別の Go モジュール。replace で ami-publish を参照する）
    main.go                              設定値ファイルの全環境について 4 つのスタックを定義する
    stacks/
      environment.go                     1 環境分のスタックの定義、スタックの共通の設定（合成の設定・出力・Export）
      release_instance_stack.go          リリース用インスタンスの IAM ロール
      health_check_stack.go              ヘルスチェックの SSM ドキュメント
      launch_template_stack.go           起動テンプレート
      pipeline_stack.go                  CodePipeline・CodeBuild・S3 バケット・ロググループ
      codebuild_permissions.go           AMI 公開ツールが CodeBuild 上で使う権限
  python/                                Python 版（同じ構成）
    app.py
    ami_publish_cdk/
      configuration.py                   設定値の読み込みと命名規則（Go の configuration.go・naming.go を写したもの）
      health_check_commands.py           ヘルスチェックのコマンド（Go の healthCheckCommands を写したもの）
      stacks/
    tests/
      test_stacks.py                     4 つのスタックのテスト（生成ツールのテストの約束を写したもの。AWS には接続しない）
```

### 設定値・命名規則・固定値の持ち方

| | Go 版 | Python 版 |
|---|---|---|
| 設定値の読み込み・検証 | 生成ツールのもの（`internal/definitions.LoadConfiguration`）をそのまま使う。未知の項目もエラー | 必要な項目があるかだけ確かめる。未知の項目・値の形式の検証は、生成ツールの `--check` に任せる |
| 命名規則 | 生成ツールのもの（`naming.go`）をそのまま使う | `configuration.py` に写している |
| ヘルスチェックのコマンド・CodeBuild のイメージ | 生成ツールのもの（`internal/definitions/shared.go` で公開）を使う | `health_check_commands.py`・`configuration.py` に写している |

命名規則や固定値を変えるときは、Go（生成ツールと CDK の Go 版が共有）、Ruby（パイプラインのスタック名だけ）、Python 版の 3 か所を直す。

## 生成ツールの出力との違い（L2 にしたことによるもの）

| 違い | 内容 |
|---|---|
| 論理 ID | L2 のリソースは、論理 ID にハッシュが付く（スタックの直下の `CfnParameter`・`CfnCondition`・`CfnDocument` は同じ） |
| 自動で作られるもの | CodePipeline の L2 は、パイプラインのロールに加えて、アクションごとのロールを作る。CodeBuild の L2 は、ログ・アーティファクト・レポートの権限を自動で付ける。起動テンプレートの L2 は、`role` からインスタンスプロファイルを作る |
| 削除時の扱い | S3 バケットとロググループの L2 の既定は「スタックを削除しても残す」。生成ツールと同じく消すように `RemovalPolicy.DESTROY` にしている。バケットの中身の自動削除（`autoDeleteObjects`）は Lambda と asset を使うので使わない（削除前に中身を空にする） |
| ロググループの保存期間 | L2 の `retention` は決まった日数の列挙なので、L1 のプロパティで設定値の日数をそのまま指定している |
| 起動テンプレートの AMI | 初回は AMI を指定しないため、L2 の `machineImage` を使わず、L1 のプロパティを条件付き（`Fn::If`）で上書きしている。合成時の検証は、`ImageId` を空の文字列（`AmiId` の既定値）として形式を確かめて警告（`CloudFormation-Validate::E1152`）を出すが、空のときは `Fn::If` で指定しないので、承知済み（`Validations.of(...).acknowledge`）にしている |
| 起動テンプレートのセキュリティグループ | L2 は作るときに `security_group` を 1 つ渡さないと `connections` を使えない。1 つ目は作るときに渡し、2 つ目からは `connections` で足す。設定値の `security_group_ids` が空なら、設定値の読み込みでエラーにする（生成ツールと同じ） |
| 起動テンプレートの `Name` タグ | L2 は構成要素のパス（`myapp-staging-launch-template/LaunchTemplate`）を `Name` タグとして、起動テンプレートと、起動したインスタンス・ボリュームに付ける。生成ツールの出力と同じく付けない（`Tags.of(...).remove("Name")`） |
| ソースのアクションのロール | CodeStar Connections のソースアクションの L2 は、旧来の接頭辞の `codestar-connections:UseConnection` だけを付ける。生成ツールと同じく `codeconnections:UseConnection` も足している |
| 出力の値の差 | CodeBuild に `EncryptionKey: alias/aws/s3`（AWS の既定と同じ値）が付く。ARN の中のリージョンが `${AWS::Region}` ではなく設定値の値になる箇所がある（スタックにリージョンを指定しているため）。起動テンプレートの `MetadataOptions` に `HttpEndpoint: enabled`（既定と同じ値）が入らない |
| cfn-lint の検査 | パイプラインのスタックは、テンプレートの Metadata で W6001（出力の値が他のスタックの Import。生成ツールも外している）と W3005（L2 の CodePipeline が足す `DependsOn` が `GetAtt` による依存と重なる）を外している |

## 使い方（ライブラリの取得後）

```bash
# Go 版（Node.js は nodenv の 26.12.1。jsii が使う）
cd cdk/go
go mod tidy                     # awscdk などを取得し、go.sum を作る
cdk synth                       # cdk.out/ に全環境のテンプレートを出力する（cdk の CLI が必要）

# Python 版（Python は pyenv の 3.14.10。Homebrew の python3 で venv を作らない）
cd cdk/python
~/.pyenv/versions/3.14.10/bin/python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cdk synth                       # cdk の CLI がある場合
CDK_OUTDIR=cdk.out .venv/bin/python app.py    # cdk の CLI がなくても、同じく cdk.out/ に出力できる
.venv/bin/python -m unittest discover -s tests   # テスト（AWS には接続しない）
# Node.js が jsii の対応外の版（26 系など）だと警告が出る。消すには JSII_SILENCE_WARNING_UNTESTED_NODE_VERSION=1

# デプロイは今までどおり AWS CLI で（例: ヘルスチェックのスタック）
aws cloudformation deploy --stack-name myapp-staging-health-check \
  --template-file cdk.out/myapp-staging-health-check.template.json \
  --capabilities CAPABILITY_IAM --no-execute-changeset
```

デプロイの順は、生成ツールのときと同じ（リリース用インスタンス・ヘルスチェック・起動テンプレート → AMI 公開パイプライン）。

## Python 版のテストで確かめている約束

生成ツールのテスト（`internal/definitions/definitions_test.go`）と同じもの。

- 4 つのスタックの名前が命名規則どおり。ブートストラップの確認（`Rules`）と `CDKMetadata` がない
- 起動テンプレート: リソースは起動テンプレート・ロール・インスタンスプロファイルだけ。パラメータ（`AmiId` / `AppVersion`）と条件（`HasAmiId`）に依存するのは起動テンプレートだけ。`ImageId` は `Fn::If` で初回は指定しない。IMDSv2 必須。サブネット・ネットワークインターフェイス・UserData を指定しない。タグは `App` と `AppVersion` だけ。バージョンは Export しない
- パイプライン: V2・QUEUED・変数の順。設定値ファイルをパラメータ `ConfigFile` から CodeBuild の環境変数で渡す。CodeBuild のイメージ・タイムアウト・同時実行 1・buildspec のパス。`iam:PassRole` は L2 が自動で足す権限を含めて `PassReleaseInstanceRole` の 1 か所だけ。`AWS-RunShellScript`・`ec2:StopInstances`・CloudFormation のサービスロール・IAM ロールの作成と変更の権限がない。他のスタックのリソースを Export で参照する。AMI 公開ツールが使う出力。ソースが GitHub なら接続の利用を両方の接頭辞で許可し、CodeCommit なら CodeConnections の権限と自動起動の規則がない
- ヘルスチェック: Basic 認証の有無でのコマンドと管理ポリシー。認証情報を `curl -u` で渡さない
- リリース用インスタンス: EC2 が引き受けるロール、許可の数と対象、インスタンスプロファイル、Export

## 次の段階

| 作業 | 内容 |
|---|---|
| Go 版の合成とテスト | ライブラリ（約 84 MB）を取得して `cdk synth` を通す。Python 版で直した点（起動テンプレートのセキュリティグループの渡し方、`Name` タグ、合成時の警告の承知、`codeconnections:UseConnection`、出力の説明、cfn-lint の Metadata）は Go 版に残っているので、同じように直す。テストは Python 版のものを写す |
| 2 つの CDK 版の比較 | Go 版と Python 版の合成の結果が一致することを確かめる |
| デプロイして確かめる | 新しい環境に AWS CLI でデプロイし、パイプラインを動かす（まだしていない） |
| デプロイ用のスクリプト | 必要なら、`cdk.out/` のテンプレートを使う `up` / `down` を用意する |
