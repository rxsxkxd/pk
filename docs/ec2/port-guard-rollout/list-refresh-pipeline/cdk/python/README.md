# 一覧更新パイプラインの CDK（Python）版

[CloudFormation 版](../../cloudformation/list-refresh-pipeline.yml)と同じ一覧更新パイプラインを Python で定義する。人の作業フロー、S3 に置くもの、スクリプトを上げる手順は[一覧更新パイプラインの README](../../README.md)を参照する。

状態: ローカルでの合成・CloudFormation 版との照合・`cfn-lint` を確認した。AWS へのデプロイとパイプラインの実行はしていない。引き続き、用意だけしたオプションである。

## 定義の方針

- CDK の L1 の構成要素（`CfnBucket`・`CfnRole`・`CfnProject`・`CfnPipeline` など）で定義する。既存の YAML を読み込む方式ではない。
- CloudFormation 版と同じパラメータ・条件・論理 ID・出力を使う。手動開始、`FORCE` の受け渡し、承認、作成用・公開用ビルドの権限分離も同じ。
- 合成は AWS に接続しない。スクリプトを CDK のアセットにはせず、自動アップロードもしない。スタック作成後に、人が共通の手順で上げる。
- テンプレートにブートストラップの確認を入れない。下の AWS CLI による反映では `cdk bootstrap` は不要。

| ファイル | 内容 |
|---|---|
| `app.py` | 入口。`stackName` コンテキストでスタック名を指定できる |
| `list_refresh_stack.py` | スタックと、CodeBuild の中で流すコマンドの定義 |
| `cdk.json` | CDK CLI の設定。`app: python3 app.py` |
| `requirements.txt` | 合成に要る Python のライブラリ |
| `requirements-dev.txt` | 照合テスト用のライブラリも含む |
| `tests/test_stack.py` | CloudFormation 版との照合と、テンプレートの大きさ・パラメータの確認 |

## 準備

Python 3 と、jsii に対応する Node.js が要る。ライブラリは、このリポジトリの既存の CDK Python 版と同じ `aws-cdk-lib` 2.275.0・`constructs` 10.8.1 に固定している。

```bash
cd port-guard-rollout/list-refresh-pipeline/cdk/python
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

CDK CLI を使う場合は、別に `npm install -g aws-cdk` で入れる。

## 合成

CDK CLI がなくても、次の形で JSON のテンプレートを出せる（Node.js は要る）。

```bash
CDK_OUTDIR=cdk.out .venv/bin/python app.py
```

既定のスタック名は `port-guard-list-refresh-staging`。別の環境ではスタック名を指定する。

```bash
CDK_CONTEXT_JSON='{"stackName":"port-guard-list-refresh-production"}' \
  CDK_OUTDIR=cdk.out .venv/bin/python app.py
```

CDK CLI を使う場合:

```bash
source .venv/bin/activate
cdk synth --quiet
# 別の環境
cdk synth -c stackName=port-guard-list-refresh-production --quiet
```

どちらも `cdk.out/<スタック名>.template.json` に出る。`stackName` はスタックの名前だけを決める。リソース名や S3 の公開場所に使う環境名は、反映するときに `EnvironmentName` パラメータで渡す。

CDK 2.275.0 の合成では、条件付きの公開バケットを参照する出力 `PublishLocation` について `CloudFormation-Validate::W1001` が出ることがある。参照は `Fn::If` の `CreatePublishBucket` が真の側にあり、`cfn-lint` は警告なしで通った。

## テンプレートを確認して反映する

まず、出たテンプレートの差分を確認する。`cfn-lint` は別にインストールする。

```bash
cfn-lint cdk.out/port-guard-list-refresh-staging.template.json

# スタックを作る。既存の公開バケットを使う場合は PublishBucketName=<名前> を足す。
aws cloudformation deploy \
  --stack-name port-guard-list-refresh-staging \
  --template-file cdk.out/port-guard-list-refresh-staging.template.json \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides EnvironmentName=staging
```

パラメータは CloudFormation 版と同じ:

| 名前 | 既定値 | 内容 |
|---|---|---|
| `EnvironmentName` | なし（必須） | 環境名。パイプライン名と S3 の公開場所に使う |
| `PublishBucketName` | 空 | 空ならバージョニング付きの公開バケットを作る。既存のものを使うなら、その名前（SSE-S3 の暗号化が前提） |
| `PublishKeyPrefix` | `port-guard` | 公開場所の先頭。`<prefix>/<環境>/current/` となる |
| `RequireApproval` | `true` | `false` にすると承認のステージを省く |
| `LogRetentionInDays` | `90` | ビルドのログを残す日数 |

出力は `PipelineName`・`PipelineBucketName`・`BastionScriptsUri`・`FetchScriptZipUri`・`PublishLocation`。スタックを作った後は、[共通の手順の 2〜5](../../README.md#パイプラインの使い方)で、踏み台サーバーの手順のスクリプト 5 つと取得スクリプトの圧縮ファイルを上げ、パイプラインを開始する。初回の個別許可の IP の一覧は、人の作業フローで上げておく。

既存の CloudFormation 版と論理 ID はそろえているが、デプロイ済みのスタックを相互に更新する操作は未検証。既存環境の更新では変更セットを確認する。

## ローカルの確認

```bash
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m unittest discover -s tests -v
```

テストは、合成したテンプレートと CloudFormation 版のパラメータ・条件・全リソース・出力を照合する。`Fn::GetAtt` の文字列／配列の表記と、buildspec の YAML／JSON の表記をそろえて比べる。テンプレート全体の説明文と形式の宣言は照合から除く。AWS には接続しない。

CDK の構成要素の仕様: [CfnPipeline](https://docs.aws.amazon.com/cdk/api/v2/python/aws_cdk.aws_codepipeline/CfnPipeline.html)。
