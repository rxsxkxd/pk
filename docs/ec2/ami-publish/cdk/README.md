# AMI 公開パイプラインの仕組みの CDK 版（Go・Python）

仕組みの生成ツール（`cmd/generate-definitions`）が作る 4 つのスタックを、AWS CDK の L2 の構成要素で定義したもの。Go 版（`go/`）と Python 版（`python/`）の 2 つがあり、内容は同じ。

> 状態: **骨組み（未実行）**。CDK のライブラリ（Python の `aws-cdk-lib` 約 60 MB、Go の `awscdk` 約 84 MB）をまだ取得していないので、合成（`cdk synth`）も型の確認もしていない。確かめたのは、Go の構文（`gofmt`）、Python の構文（`py_compile`）、Python に写したヘルスチェックのコマンドが生成ツールの出力と一致すること、だけ

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
| 起動テンプレートの AMI | 初回は AMI を指定しないため、L2 の `machineImage` を使わず、L1 のプロパティを条件付き（`Fn::If`）で上書きしている |

## 使い方（ライブラリの取得後）

```bash
# Go 版（Node.js は nodenv の 26.12.1。jsii が使う）
cd cdk/go
go mod tidy                     # awscdk などを取得し、go.sum を作る
cdk synth                       # cdk.out/ に全環境のテンプレートを出力する（cdk の CLI が必要）

# Python 版（Python は pyenv の 3.14.10）
cd cdk/python
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cdk synth

# デプロイは今までどおり AWS CLI で（例: ヘルスチェックのスタック）
aws cloudformation deploy --stack-name myapp-staging-health-check \
  --template-file cdk.out/myapp-staging-health-check.template.json \
  --capabilities CAPABILITY_IAM --no-execute-changeset
```

デプロイの順は、生成ツールのときと同じ（リリース用インスタンス・ヘルスチェック・起動テンプレート → AMI 公開パイプライン）。

## 次の段階（未着手）

| 作業 | 内容 |
|---|---|
| ライブラリの取得と合成 | 上の手順で `cdk synth` を通し、型やプロパティ名の誤りを直す |
| テスト | CDK の assertions（`Template.fromStack`）で、Go 版・Python 版それぞれ、生成ツールのテストで守っている約束を確かめる。スタック名・Export 名・出力、`iam:PassRole` が `PassReleaseInstanceRole` の 1 か所だけ（L2 が自動で足す権限を含めて）、`AWS-RunShellScript` と `ec2:StopInstances` がない、起動テンプレートのスタックでパラメータに依存するのが起動テンプレートだけ |
| 2 つの CDK 版の比較 | Go 版と Python 版の `cdk synth` の結果が一致することを確かめる |
| 生成ツールとの比較 | 論理 ID 以外の主要な部分（名前・Export・IAM の許可）が一致することを確かめる |
| デプロイ用のスクリプト | 必要なら、`cdk.out/` のテンプレートを使う `up` / `down` を用意する |
