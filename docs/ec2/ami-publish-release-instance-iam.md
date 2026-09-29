# リリース用インスタンス（AMI の作成元）の IAM ロールの許可ポリシー

> スコープ: AMI 公開パイプライン（[`ami-publish/`](./ami-publish/README.md)、フェーズ 1）の AMI の作成元になる、常時起動のリリース用 EC2 インスタンスが、インスタンスプロファイル（IAM ロール）に持つべき許可ポリシーと、その設定方法。**現時点で判明しているもの**をまとめる
>
> スコープ外: CodeBuild のサービスロール・CloudFormation のサービスロール（パイプラインのスタックが作る）、AMI から起動する本番インスタンスのロール（起動テンプレートのスタックが作る）、フェーズ 3（リリース検証の自動化）で必要になる許可
>
> 関連: [確認手順書](./ami-publish-environment-verification.md) / [トラブルシューティング](./ami-publish-troubleshooting.md)

## 前提: どのロールの話か

AMI 公開パイプラインでは、IAM ロールが 4 種類登場する。このドキュメントで扱うのは **1 だけ**。

| # | ロール | 誰が作るか | このドキュメント |
|---|---|---|---|
| 1 | **リリース用インスタンスのロール（インスタンスプロファイル）** | **このリポジトリの管理外。担当者が用意する** | **対象** |
| 2 | CodeBuild のサービスロール（AMI の作成、SSM の実行、スタックの更新） | パイプラインのスタック | 対象外 |
| 3 | 起動テンプレートのスタックを更新する CloudFormation のサービスロール | パイプラインのスタック | 対象外 |
| 4 | AMI から起動する本番インスタンスのロール | 起動テンプレートのスタック | 対象外 |

ヘルスチェックを省略する実行（パイプライン変数 `HEALTH_CHECK=false`）では、このロールの許可は使わない（SSM も使わない）。

AMI の作成や起動テンプレートの更新は、CodeBuild（ロール 2）が行う。リリース用インスタンスのロールに、AMI の作成などの権限は**不要**。リリース用インスタンスのロールが必要なのは、インスタンス上の SSM Agent とヘルスチェックの処理が AWS を呼ぶ部分だけである。

AMI にはロールは含まれない（ロールはインスタンスに付くもので、ディスクの中身ではない）。そのため、このロールの権限が本番インスタンスに引き継がれることはない。

## 必要な許可の一覧

| # | 許可 | 何のために必要か | 必須 / 条件付き | 設定方法 |
|---|---|---|---|---|
| A | AWS 管理ポリシー `AmazonSSMManagedInstanceCore` | SSM の管理対象になり、SSM Run Command（ヘルスチェックの SSM ドキュメント）を受け取るため。ステップ 0（AMI 作成前の SSM の確認）とステップ 3（再起動後の接続待ち）でも、これがないと「SSM に未登録」になる | **必須** | 管理ポリシーをロールにアタッチ |
| B | CloudWatch Logs への書き込み（ロググループ `/<application_name>/<環境>/ami-publish`） | ヘルスチェックの出力を CloudWatch Logs に送るため（AMI 公開ツールが SSM Run Command に出力先としてこのロググループを指定している。書き込むのはインスタンス上の SSM Agent） | **推奨**（ない場合、ヘルスチェック自体は動くが出力がロググループに残らず、失敗時の調査がしにくくなる。パイプラインは警告を出して先に進む） | インラインポリシー（下記） |
| C | SSM Parameter Store の Basic 認証のパラメーターの読み取り | ヘルスチェックが Basic 認証の情報を取り出すため | **Basic 認証を使う場合**（`health_check.basic_auth_parameter_name` を設定した場合） | ヘルスチェックのスタックが作る管理ポリシー（出力 `BasicAuthParameterReadPolicyArn`）をアタッチ |

### A. AmazonSSMManagedInstanceCore

AWS 管理ポリシーをそのままアタッチする。

```
arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### B. CloudWatch Logs への書き込み

ロググループはパイプラインのスタックが作る（名前は `application_name` と環境名から自動で決まる。例: `/myapp/staging/ami-publish`）。SSM Agent が Run Command の出力を送るために、次の許可が必要。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WriteHealthCheckOutput",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:<リージョン>:<アカウント ID>:log-group:/myapp/staging/ami-publish:*"
    },
    {
      "Sid": "FindLogGroup",
      "Effect": "Allow",
      "Action": "logs:DescribeLogGroups",
      "Resource": "*"
    }
  ]
}
```

- ロググループはパイプラインのスタックが事前に作るので、`logs:CreateLogGroup` は不要
- 現時点では、この許可はどのスタックも作らない。担当者がインラインポリシーとして付ける（C と同じく、ヘルスチェックのスタックに管理ポリシーとして含める改善は可能。[今後の改善](#今後の改善)）

### C. Basic 認証のパラメーターの読み取り

**前提: パラメーターは、既定の `aws/ssm` キーで暗号化した SecureString にする**（`aws ssm put-parameter --type SecureString` で `--key-id` を指定しない）。既定のキーなら、ロールに KMS の許可（`kms:Decrypt`）は不要。カスタマー管理の KMS キーで暗号化したパラメーターには対応しない（パイプラインは開始時に確かめ、既定のキー以外なら止まる）。

ヘルスチェックのスタック（`<application_name>-<環境>-health-check`）が、`health_check.basic_auth_parameter_name` を設定したときだけ、読み取り用の管理ポリシーを作る。中身は次のとおり（生成されるので、担当者は ARN を取得してアタッチするだけ）。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:<リージョン>:<アカウント ID>:parameter/myapp/staging/health-check/basic-auth"
    }
  ]
}
```

## 許可以外に必要なこと（参考）

IAM の許可だけでは足りないもの。詳細は [トラブルシューティング 1](./ami-publish-troubleshooting.md#1-ssm-の管理対象になっていない)。

| 項目 | 内容 |
|---|---|
| SSM Agent | インストール済みで、自動起動が有効（AMI 作成時の再起動の後も起動すること） |
| SSM への経路 | プライベートサブネットなら、NAT ゲートウェイ、または VPC エンドポイント（`ssm` / `ssmmessages` / `ec2messages`）。B のために `logs` のエンドポイントも必要（NAT がない場合） |
| AWS CLI | C を使う場合（ヘルスチェックが `aws ssm get-parameter` で取り出す） |
| `curl` | ヘルスチェックが使う |
| インスタンスのメタデータ（IMDS） | 有効であること（SSM Agent と AWS CLI がロールの認証情報を取得するため） |

## 設定方法

### 1. リリース用インスタンスにロールが付いているか確認する

```bash
aws ec2 describe-instances --instance-ids <インスタンス ID> \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text
```

- ARN が表示された → そのインスタンスプロファイルのロールに、手順 3 で許可を付ける。ロール名は次で確認する:

  ```bash
  aws iam get-instance-profile --instance-profile-name <インスタンスプロファイル名> \
    --query 'InstanceProfile.Roles[0].RoleName' --output text
  ```

- `None` → 手順 2 でロールとインスタンスプロファイルを作って付ける

### 2. ロールとインスタンスプロファイルを作って付ける（ロールがない場合）

```bash
ROLE=myapp-staging-release-instance

# EC2 が引き受けられるロール
aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow", "Principal": { "Service": "ec2.amazonaws.com" }, "Action": "sts:AssumeRole" }]
}'

# インスタンスプロファイルを作り、ロールを入れる
aws iam create-instance-profile --instance-profile-name "$ROLE"
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"

# リリース用インスタンスに付ける（起動中のままでよい）
aws ec2 associate-iam-instance-profile --instance-id <インスタンス ID> --iam-instance-profile Name="$ROLE"
```

既に別のインスタンスプロファイルが付いていて入れ替える場合は、`aws ec2 replace-iam-instance-profile-association` を使う（関連付け ID は `aws ec2 describe-iam-instance-profile-associations` で確認する）。

### 3. 許可を付ける

```bash
ROLE=<リリース用インスタンスのロール名>

# A: SSM の管理対象になるための AWS 管理ポリシー
aws iam attach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# B: ヘルスチェックの出力を CloudWatch Logs に送る（上の JSON を write-health-check-output.json に保存しておく）
aws iam put-role-policy --role-name "$ROLE" --policy-name write-health-check-output \
  --policy-document file://write-health-check-output.json

# C: Basic 認証のパラメーターの読み取り（Basic 認証を使う場合。ヘルスチェックのスタックのデプロイ後）
POLICY_ARN=$(aws cloudformation describe-stacks --stack-name myapp-staging-health-check \
  --query "Stacks[0].Outputs[?OutputKey=='BasicAuthParameterReadPolicyArn'].OutputValue" --output text)
aws iam attach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN"

```

### 4. SSM Agent に反映させる

ロールを新しく付けた場合や、A を後から付けた場合は、SSM Agent がすぐには認識しないことがある。インスタンス上で SSM Agent を再起動する（SSM で接続できない場合は、SSH か EC2 シリアルコンソールから）。

```bash
sudo systemctl restart amazon-ssm-agent          # Amazon Linux など
sudo snap restart amazon-ssm-agent               # Ubuntu（snap 版）
```

### 5. 確認する

AMI 公開パイプラインは、ヘルスチェックを行う実行（既定）では、開始時（AMI を作る前）に、このロールに A〜C の許可があるかを IAM のポリシーシミュレーターで自動的に判定する（ステップ 0b。A・C の不足は、不足している許可を一覧にして AMI を作らずに止まる。B の不足は警告のログ `release_instance_permissions_warning` を出して先に進む）。設定した直後は、手元から `bin/ami_publish plan` を実行すれば、パイプラインを動かさずに同じ判定ができる。

ポリシーシミュレーターは、ロールのポリシー（と許可の境界）で判定する。ネットワークの経路、AWS CLI の有無は判定しないので、下の確認も行う。あわせて、Basic 認証のパラメーターが既定の `aws/ssm` キーで暗号化された SecureString であることも確かめる。

| 確認 | コマンド | 期待結果 |
|---|---|---|
| A: SSM の管理対象 | `aws ssm describe-instance-information --filters Key=InstanceIds,Values=<インスタンス ID> --query 'InstanceInformationList[0].PingStatus'` | `Online` |
| ロールの許可の一覧 | `aws iam list-attached-role-policies --role-name <ロール名>` と `aws iam list-role-policies --role-name <ロール名>` | A（と C）がアタッチされ、B のインラインポリシーがある |
| B・C を含めた動作 | ヘルスチェックの SSM ドキュメントを単体で実行する（[確認手順書 4-6](./ami-publish-environment-verification.md#4-デプロイ結果の確認)） | `Success`。CloudWatch Logs のロググループに出力が残る |
| C: パラメーターの読み取り（インスタンス上で） | `aws ssm get-parameter --name <パラメーター名> --with-decryption --query Parameter.Name` | パラメーター名が表示される（値は表示しない） |
| 全体 | 手元から `bin/ami_publish plan` | ステップ 0 で `ssm_managed`、ステップ 0b で `release_instance_permissions_checked`（`missing` が空）がログに出る |

## 今後の改善

パイプラインによる許可の判定（ステップ 0b）は実装済み。


| 改善 | 内容 |
|---|---|
| B を管理ポリシーとして生成する | C と同じく、ヘルスチェック（またはパイプライン）のスタックに B の管理ポリシーを含めて ARN を出力すれば、担当者は ARN をアタッチするだけになり、ロググループ名の手入力も不要になる |
| フェーズ 3 で必要になる許可 | リリース検証を自動化すると、デプロイキーの読み取り（Secrets Manager）や、検証用の設定の読み取り（Parameter Store）などが加わる見込み（[リリース検証の設計](./ami-build-pipeline.md)） |
