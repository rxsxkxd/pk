# リリース用インスタンス（AMI の作成元）の IAM ロールの許可ポリシー

> スコープ: AMI 公開パイプライン（[`ami-publish/`](./ami-publish/README.md)、フェーズ 1）の AMI の作成元になる、常時起動のリリース用 EC2 インスタンスに付ける IAM ロールの許可ポリシーと、その用意のしかた。**現時点で判明しているもの**をまとめる
>
> スコープ外: CodeBuild のサービスロール（パイプラインのスタックが作る）、AMI から起動する本番インスタンスのロール（起動テンプレートのスタックが作る）、フェーズ 3（リリース検証の自動化）で必要になる許可
>
> 関連: [確認手順書](./ami-publish-environment-verification.md) / [トラブルシューティング](./ami-publish-troubleshooting.md) / 全ロールの一覧は [IAM ロールと許可ポリシーの現状](./ami-publish-iam-roles.md) / 紐付けのフローは [ヘルスチェックの区間だけロールを紐付けるフロー](./ami-publish-health-check-role-association-flow.md)

## 前提: どのロールの話か

AMI 公開パイプラインでは、IAM ロールが 3 種類登場する。このドキュメントで扱うのは **1 だけ**。

| # | ロール | 誰が作るか | このドキュメント |
|---|---|---|---|
| 1 | **リリース用インスタンスのロール（インスタンスプロファイル）** | **リリース用インスタンスの IAM ロールのスタック**（`<application_name>-<環境>-release-instance`）。担当者がデプロイする | **対象** |
| 2 | CodeBuild のサービスロール（AMI の作成、SSM の実行、起動テンプレートのスタックの更新、1 の紐付けと解除） | パイプラインのスタック | 対象外 |
| 3 | AMI から起動する本番インスタンスのロール | 起動テンプレートのスタック | 対象外 |

**リリース用インスタンスには、普段はロールを付けない。** AMI 公開ツールが、ヘルスチェックのための区間（AMI の作成の直前からヘルスチェックの完了まで）だけ 1 のインスタンスプロファイルを紐付け、終わったら解除する（失敗しても必ず解除する）。担当者が紐付ける作業はない。

- ヘルスチェックを省略する実行（パイプライン変数 `HEALTH_CHECK=false`）では、紐付けも行わず、このロールは使わない
- リリース用インスタンスに**別の**インスタンスプロファイルが付いていると、パイプラインは入れ替えずに止まる（AMI は作らない）。アプリのために別のロールを付けているインスタンスには対応しない
- AMI の作成や起動テンプレートの更新は CodeBuild（ロール 2）が行う。リリース用インスタンスのロールに、AMI の作成などの権限は**不要**。必要なのは、インスタンス上の SSM Agent とヘルスチェックの処理が AWS を呼ぶ部分だけである
- AMI にはロールは含まれない（ロールはインスタンスに付くもので、ディスクの中身ではない）。そのため、このロールの権限が本番インスタンスに引き継がれることはない

## 必要な許可の一覧

リリース用インスタンスの IAM ロールのスタックが作るロールには、次の許可がすべて含まれている（C は Basic 認証を設定した場合だけ）。担当者が個別に付ける必要はない。

| # | 許可 | 何のために必要か | 必須 / 条件付き | スタックでの付け方 |
|---|---|---|---|---|
| A | AWS 管理ポリシー `AmazonSSMManagedInstanceCore` | SSM の管理対象になり、SSM Run Command（ヘルスチェックの SSM ドキュメント）を受け取るため。ステップ 3（再起動後の接続待ち）で、これがないと「SSM に未登録」になる | **必須** | 管理ポリシーのアタッチ |
| B | CloudWatch Logs への書き込み（ロググループ `/<application_name>/<環境>/ami-publish`） | ヘルスチェックの出力を CloudWatch Logs に送るため（AMI 公開ツールが SSM Run Command に出力先としてこのロググループを指定している。書き込むのはインスタンス上の SSM Agent） | **推奨**（ない場合、ヘルスチェック自体は動くが出力がロググループに残らない。パイプラインは警告を出して先に進む） | インラインポリシー `health-check` |
| C | SSM Parameter Store の Basic 認証のパラメーターの読み取り | ヘルスチェックが Basic 認証の情報を取り出すため | **Basic 認証を使う場合**（`health_check.basic_auth_parameter_name` を設定した場合） | インラインポリシー `health-check` |

### A. AmazonSSMManagedInstanceCore

```
arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### B. CloudWatch Logs への書き込み

ロググループはパイプラインのスタックが作る（名前は `application_name` と環境名から自動で決まる。例: `/myapp/staging/ami-publish`）。ロググループは事前に作られるので、`logs:CreateLogGroup` は不要。

```json
{
  "Sid": "WriteHealthCheckOutput",
  "Effect": "Allow",
  "Action": ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"],
  "Resource": "arn:aws:logs:<リージョン>:<アカウント ID>:log-group:/myapp/staging/ami-publish:*"
},
{
  "Sid": "FindLogGroup",
  "Effect": "Allow",
  "Action": "logs:DescribeLogGroups",
  "Resource": "*"
}
```

### C. Basic 認証のパラメーターの読み取り

**前提: パラメーターは、既定の `aws/ssm` キーで暗号化した SecureString にする**（`aws ssm put-parameter --type SecureString` で `--key-id` を指定しない）。既定のキーなら、ロールに KMS の許可（`kms:Decrypt`）は不要。カスタマー管理の KMS キーで暗号化したパラメーターには対応しない（パイプラインは開始時に確かめ、既定のキー以外なら止まる）。

```json
{
  "Sid": "ReadBasicAuthParameter",
  "Effect": "Allow",
  "Action": "ssm:GetParameter",
  "Resource": "arn:aws:ssm:<リージョン>:<アカウント ID>:parameter/myapp/staging/health-check/basic-auth"
}
```

ヘルスチェックのスタックにも、同じ許可の管理ポリシー（出力 `BasicAuthParameterReadPolicyArn`）がある。ロールを紐付ける方式に変える前の名残で、今は使わない（[IAM ロールと許可ポリシーの現状](./ami-publish-iam-roles.md) の「気になる点」）。

## 許可以外に必要なこと（参考）

IAM の許可だけでは足りないもの。詳細は [トラブルシューティング 1](./ami-publish-troubleshooting.md#1-ssm-の管理対象になっていない)。

| 項目 | 内容 |
|---|---|
| SSM Agent | インストール済みで、**自動起動が有効**（紐付けの後の再起動・起動で SSM Agent が起動し、そのときにロールの認証情報を取るため） |
| SSM への経路 | プライベートサブネットなら、NAT ゲートウェイ、または VPC エンドポイント（`ssm` / `ssmmessages` / `ec2messages`）。B のために `logs` のエンドポイントも必要（NAT がない場合） |
| AWS CLI | C を使う場合（ヘルスチェックが `aws ssm get-parameter` で取り出す） |
| `curl` | ヘルスチェックが使う |
| インスタンスのメタデータ（IMDS） | 有効であること（SSM Agent と AWS CLI がロールの認証情報を取得するため） |
| インスタンスプロファイルの紐付け | **普段は何も付いていないこと**（別のプロファイルが付いているとパイプラインが止まる） |

## 用意のしかた

### 1. リリース用インスタンスにインスタンスプロファイルが付いていないことを確認する

```bash
aws ec2 describe-iam-instance-profile-associations \
  --filters Name=instance-id,Values=<インスタンス ID> \
  --query 'IamInstanceProfileAssociations[?State==`associated`].[AssociationId,IamInstanceProfile.Arn]' --output text
```

- 何も表示されない → 手順 2 へ
- 別のインスタンスプロファイルが表示された → そのプロファイルが不要なら外す（`aws ec2 disassociate-iam-instance-profile --association-id <紐付けの ID>`）。アプリのために必要なら、この方式は使えない

### 2. リリース用インスタンスの IAM ロールのスタックをデプロイする

仕組みの生成ツールが、テンプレート `generated/cloudformation/<環境>/release-instance-stack.yml` を生成する（定義は `internal/definitions/release_instance_stack.go`）。

| リソース・出力 | 内容 |
|---|---|
| IAM ロール | EC2 が引き受けられるロール。A〜C を持つ。名前は CloudFormation が自動で付ける |
| インスタンスプロファイル | 上のロールを入れる |
| 出力（Export する） | `InstanceProfileArn`、`RoleArn`（パイプラインのスタックが参照する） |
| 出力（Export しない） | `InstanceProfileName`、`RoleName` |

このスタックは、パイプラインの仕組みではなくリリース用インスタンス側の設定のため、**デプロイ用シェルスクリプト（`generated/deploy/<環境>.sh` の `up` / `down`）には含めない**（フェーズ 3 でインスタンスの更新の仕組みに移す可能性がある）。ただし、パイプラインのスタックがこのスタックの Export を参照するので、**`up` より先にデプロイしておく**。`ami-publish/` のルートで、次のとおりデプロイする。

```bash
STACK=myapp-staging-release-instance   # <application_name>-<環境>-release-instance

# 変更セットを作る（反映はしない）。中身を確認してから反映する
aws cloudformation deploy --region ap-northeast-1 --stack-name "$STACK" \
  --template-file generated/cloudformation/staging/release-instance-stack.yml \
  --capabilities CAPABILITY_IAM --no-execute-changeset
aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name <表示された変更セット名>
aws cloudformation execute-change-set  --stack-name "$STACK" --change-set-name <表示された変更セット名>
aws cloudformation wait stack-create-complete --stack-name "$STACK"   # 更新のときは stack-update-complete
```

変更セットを確認する観点: `AWS::IAM::Role` と `AWS::IAM::InstanceProfile` の 2 つだけ。

インスタンスへの紐付けは行わない（パイプラインが、ヘルスチェックの区間だけ行う）。

注意:

- 許可の変更（Basic 認証の追加など）は、設定値を直して再生成し、同じ手順でスタックを更新する
- **パイプラインのスタックが Export を参照している間は、このスタックは削除できない**（先にパイプラインのスタックを削除する）
- 削除する前に、リリース用インスタンスに紐付けが残っていないことを確かめる（手順 1 のコマンド）。パイプラインが異常終了して紐付けが残っていると、削除後も削除済みのプロファイルを指す紐付けが残る

### 3. 確認する

リリース用インスタンスには普段ロールが付いていないので、パイプラインの外では SSM の管理対象（`Online`）にはならない。確認は次の 2 つで行う。

| 確認 | コマンド | 期待結果 |
|---|---|---|
| 開始時の確認と許可の判定 | 手元から `bin/ami_publish plan`（AWS に書き込まない） | ステップ 0 で `profile_association_checked`、ステップ 0b で `release_instance_permissions_checked`（`missing` が空）、`profile_association_planned` がログに出る |
| 紐付け・ヘルスチェック・解除を含めた動作 | パイプラインを実行する（[確認手順書](./ami-publish-environment-verification.md)） | ログに `profile_associated` → `instance_online` → `health_check_passed` → `profile_disassociated` が出る。終了後、手順 1 のコマンドで紐付けが残っていない |

パイプラインは、ヘルスチェックを行う実行（既定）では、開始時（AMI を作る前）に、このロールに A〜C の許可があるかを IAM のポリシーシミュレーターで判定する（ステップ 0b。A・C の不足は AMI を作らずに止まる。B の不足は警告のログ `release_instance_permissions_warning` を出して先に進む）。ポリシーシミュレーターは、ネットワークの経路、AWS CLI の有無は判定しない。

## 今後の改善

| 改善 | 内容 |
|---|---|
| ヘルスチェックのスタックの管理ポリシーの削除 | C の管理ポリシー（`BasicAuthParameterReadPolicy`）は今は使わないので、削除できる |
| リリース用インスタンスの IAM ロールのスタックの置き場所 | フェーズ 3（リリース検証）で、インスタンスの更新の仕組み側に移す可能性がある。それまでは `up` / `down` に含めず、担当者が個別にデプロイする |
| フェーズ 3 で必要になる許可 | リリース検証を自動化すると、デプロイキーの読み取り（Secrets Manager）などが加わる見込み。紐付けの区間をリリース検証まで広げるかも決める |
