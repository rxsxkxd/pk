# EC2 Image Builder の定義: 海外からの確認の拠点（チェック用のクライアント。Amazon Linux 2023。下書き・未検証）

> 位置付け: [海外からの確認の拠点](../../outside-probe.md) のインスタンスを起動するための AMI を、EC2 Image Builder で作る定義の**下書き**。**AWS へのデプロイも、CloudFormation の検証（cfn-lint など）もしていない**。手元での再現は [Docker の定義](../docker/README.md)。
>
> 作成日: 2026-10-29

## ファイル

| ファイル | 内容 |
|---|---|
| `outside-probe-image.yml` | CloudFormation のテンプレート。ビルド用のインスタンスのロール、コンポーネント、イメージのレシピ、インフラストラクチャの設定、配布の設定、イメージのパイプラインを 1 つのスタックで作る |

## 作る AMI

| 項目 | 内容 |
|---|---|
| 親イメージ | AWS が管理する最新の Amazon Linux 2023。既定は **arm64**（`t4g.nano` で動かすため）。パラメーター `Architecture` で `x86_64` にも変えられる（`InstanceType` も合わせる）。`ParentImage` で AMI などを直接指定することもできる |
| 入れる道具 | `python3`・`curl`（AL2023 に最初から入っている）、`nmap-ncat`（`nc`）、`openssl` |
| 確認の処理 | `/usr/local/bin/port-guard-probe`（[`../port-guard-probe`](../port-guard-probe) と同じ中身を、コンポーネントに埋め込んでいる） |
| `validate` の段 | `port-guard-probe --help`、`nc --version`、`openssl version`、外への接続の確認（`port-guard-probe checkip.amazonaws.com 443:tls`） |
| `test` の段 | できた AMI から起動したインスタンスで、`port-guard-probe --help` と、外への接続の確認（`checkip.amazonaws.com` の 443・80 番） |
| AMI の名前 | `<NamePrefix>-<Architecture>-<ビルドの日時>`（既定の `NamePrefix` は `port-guard-outside-probe`） |
| AMI のタグ | `Purpose=port-guard-rollout-outside-probe`、`Architecture`、`RecipeVersion` |
| SSM Agent | AL2023 の AMI に最初から入っている。ビルドの後も残す（拠点には SSM だけで入るため） |

## port-guard-probe の埋め込み

コンポーネントの `Data` に、ヒアドキュメントで埋め込んでいる（`cat > /usr/local/bin/port-guard-probe <<'PORT_GUARD_PROBE_EOF'`）。

| 点 | 内容 |
|---|---|
| 埋め込みにした理由 | S3 に置くと、バケットと、ビルド用のインスタンスの読み取りの権限が増える。`port-guard-probe` は小さい（`Data` の全体で約 6,600 文字）ので、コンポーネントの `Data` の上限（16,000 文字と記憶しているが**未確認**）に十分収まる |
| 中身をそろえる | `../port-guard-probe` を直したら、テンプレートの埋め込みも同じ中身に直し、`ComponentVersion` と `RecipeVersion` を上げる。単体のテスト（`tests/test_outside_probe.py`）が、埋め込みと本体の食い違いと、`Data` の大きさを確かめる |

## 作り方

前提:

- 拠点を置くリージョン（例: us-west-2）の、インターネットに出られるサブネット（既定の VPC の公開のサブネットでよい。ビルド用のインスタンスにパブリック IP が付くこと）
- 受信なし、送信は TCP 80・443・22 だけのセキュリティグループ（dnf のリポジトリ、外への接続の確認、SSM の窓口のため）

```bash
cd port-guard-rollout/outside-probe/image-builder

# スタックの作成・更新
aws cloudformation deploy --region us-west-2 \
  --stack-name port-guard-outside-probe-image \
  --template-file outside-probe-image.yml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides SubnetId=<サブネットの ID> SecurityGroupId=<セキュリティグループの ID>

# AMI を作る（手動で実行する。定期実行はしない）
aws imagebuilder start-image-pipeline-execution --region us-west-2 \
  --image-pipeline-arn <スタックの出力 ImagePipelineArn>

# できた AMI の ID
aws imagebuilder list-image-pipeline-images --region us-west-2 \
  --image-pipeline-arn <スタックの出力 ImagePipelineArn> \
  --query 'imageSummaryList[].[name,state.status,outputResources.amis[0].image]' --output table
```

できた AMI から拠点を起動するときは、[海外からの確認の拠点](../../outside-probe.md) のテンプレートの案の `ProbeAmiId` に AMI の ID を渡す（UserData での道具の導入は行われない）。

x86_64 で作るとき:

```bash
aws cloudformation deploy ... --parameter-overrides Architecture=x86_64 InstanceType=t3.small RecipeVersion=1.0.1 ...
```

## 版の上げ方

| 変えるもの | 上げる版 |
|---|---|
| コンポーネントの中身（道具、`port-guard-probe` の埋め込み、確認の処理） | `ComponentVersion` と `RecipeVersion` |
| 親イメージ（`Architecture`・`ParentImage`） | `RecipeVersion` |
| インスタンスタイプ、サブネット、ログの置き場所 | 不要 |

## 未確認の点

| # | 点 |
|---|---|
| 1 | AWS が管理する AL2023 のイメージの名前（`amazon-linux-2023-arm64`・`amazon-linux-2023-x86`）と、`x.x.x` で最新を指す書き方 |
| 2 | `AWS::ImageBuilder::Component` の `Data` の上限（16,000 文字と記憶している） |
| 3 | AWSTOE の `ExecuteBash` で、複数行のコマンド（ヒアドキュメント）がそのまま実行されるか |
| 4 | `t4g.small` でのビルドの時間と費用 |
| 5 | ビルド用のインスタンスから `checkip.amazonaws.com` に届くか（サブネットとセキュリティグループしだい） |
