# rule-refresh-via-ssm — 各サーバーのルールを、ルールのデプロイ先の新しいルールに更新する（SSM）

> **ルールの更新**とは、port-guard（iptables ＋ ipset）を**入れ済み**の台で、ipset の集合の中身だけを、ルールのデプロイ先にある新しい一覧に入れ替えること。iptables のルールには触らない。port-guard を最初に入れる初期設定（`install`・`enable`。[手順](../../steps.md)）とは別のもので、初期設定が済んでいない台では何も変えずに失敗する。

[全体の流れの図](../list-refresh-flow.svg)の「**SSM ルール取得**」（ipset 対象サーバー → S3）と、その先の「**IP制限の有効化**」に当たる部分。SSM で、環境ごとの更新対象サーバーに、ルールのデプロイ先からの取得・照合・ipset の入れ替えを流す。流し方は 2 つある。

| 流し方 | 動かす人・きっかけ | 対象 | 流し方 |
|---|---|---|---|
| 手動の更新 | 作業者が `refresh_rules.rb` で流す（Run Command） | 環境のタグで引いた一覧を、人が目で確かめたもの | 1 台ずつ。1 台でも失敗したら残りは流さない |
| 定期更新 | 毎週月曜・木曜の日本時間 11:00 に無人で流れる（State Manager の関連付け） | 環境のタグと用途タグの両方が付いた台すべて | 全台に並列。失敗した台は通知し、実行の履歴に残す |

どちらも同じ**ルールの更新ドキュメント**（SSM のコマンドのドキュメント）を流す。

**インスタンスへの設定の手順は [instance-setup.md](instance-setup.md) にまとめている**（ドキュメント・ポリシー・タグ・ロール・手動での確かめ・定期更新の開始・運用）。定期更新の設計と、EventBridge Scheduler との比べは [scheduled-refresh-design.md](scheduled-refresh-design.md)。

状態（2026-11-19）: テンプレートとコマンドを用意した。`cfn-lint`・`ruby -c`・`bash -n`（ルールの更新ドキュメントの中のスクリプトを取り出して）の確認だけで、**AWS に対しては流していない**。

## 用語

[親フォルダの用語](../README.md#用語)（ルールのデプロイ先バケット・ルールのデプロイ先など）に加えて、次の名前を使う。

| 名前 | 指すもの |
|---|---|
| 更新対象サーバー | ルールを入れる EC2 のインスタンス。図の「ipset 対象サーバー」。port-guard（iptables ＋ ipset）を入れ済みで、SSM に登録されていて応答するもの |
| 環境のタグ | 更新対象サーバーがどの環境（`development`・`staging`・`production`）かを表すタグ。既定はキー `Environment`、値は環境の名前。手動の更新と定期更新の両方で使う |
| 用途タグ | 定期更新に入れる台だけに付けるタグ。定期更新は、環境のタグと用途タグの**両方**が付いた台だけに流す。実際のキーと値は決まっていない（スタックのパラメータ `PurposeTagKey`・`PurposeTagValue`。仮の既定は `PortGuardScheduledRefresh` = `true`） |
| ルールの更新ドキュメント | ルールの更新スクリプトを中身にした、自分で作る SSM のコマンドのドキュメント `port-guard-refresh-rules`（[cloudformation/rule-refresh-document.yml](cloudformation/rule-refresh-document.yml)。アカウントに 1 つ）。**ルールの更新スクリプトの正本**。ルールのデプロイ先・リージョン・IPv6 も流すかをパラメータで受け取る |
| ルールの更新スクリプト | ルールの更新ドキュメントの中のシェルスクリプト（更新対象サーバーで root で流れる）。ルールのデプロイ先から照合の値（`SHA256SUMS`）と ipset 入れ替えスクリプトを取り、照合してから ipset 入れ替えスクリプトを流す |
| ルールの読み取りポリシー | 更新対象サーバーの IAM ロールに付ける管理ポリシー `port-guard-rule-read-<環境>`。その環境のルールのデプロイ先の `s3:GetObject` だけを許す（[cloudformation/rule-read-policy.yml](cloudformation/rule-read-policy.yml)） |
| インスタンスの一覧ファイル | 手動の更新で使う、更新対象サーバーを 1 行 1 台で書いた TSV（`instance-lists/<環境>.tsv`）。列は「インスタンス ID・パブリック IP・Name タグ」 |
| 定期更新の関連付け | 定期更新を行う State Manager の関連付け。環境ごとに 2 つ（`port-guard-refresh-rules-<環境>-mon`・`-thu`）（[cloudformation/scheduled-refresh.yml](cloudformation/scheduled-refresh.yml)） |
| 失敗の通知の規則 | 定期更新で失敗した台を、SNS のトピックへ台ごとに知らせる EventBridge の規則 |
| 更新の記録フォルダ | 更新対象サーバーの `/var/lib/port-guard/rules/`。最後に流した ipset 入れ替えスクリプトの写しと、流した日時（`last-refreshed`）を残す |

## システムの構成

![ルールの更新の構成](system-architecture.svg)

| 置くもの | どこに | AWS のリソース | 作り方 |
|---|---|---|---|
| IP 許可ルール（ipset 入れ替えスクリプトと照合の値） | S3 のルールのデプロイ先 `port-guard/<環境>/current/` | S3 のバケット（親フォルダのルールのデプロイ先バケット） | 親フォルダの `deploy-rules.sh`（手動か CodePipeline。月曜・木曜 9:00） |
| ルールの更新スクリプト | ルールの更新ドキュメント `port-guard-refresh-rules`（アカウントに 1 つ） | `AWS::SSM::Document`（`DocumentType: Command`） | [cloudformation/rule-refresh-document.yml](cloudformation/rule-refresh-document.yml) |
| 定期実行のスケジュール | 定期更新の関連付け `port-guard-refresh-rules-<環境>-mon`・`-thu`（環境ごとに 2 つ） | `AWS::SSM::Association` | [cloudformation/scheduled-refresh.yml](cloudformation/scheduled-refresh.yml) |
| 定期実行時のエラーの定義と通知 | 失敗の通知の規則 `port-guard-refresh-rules-<環境>-failed`（環境ごと） | `AWS::Events::Rule`（送り先は既存の SNS のトピック） | 同上（`NotificationTopicArn` を渡したときだけ） |
| S3 を読む権限 | 更新対象サーバーの IAM ロール | `AWS::IAM::ManagedPolicy` `port-guard-rule-read-<環境>` | [cloudformation/rule-read-policy.yml](cloudformation/rule-read-policy.yml) |
| 更新対象サーバーの一覧（手動の更新） | 作業者の手元のインスタンスの一覧ファイル `instance-lists/<環境>.tsv`（Git に入れない） | なし（ファイル） | `list_instances.rb` が環境のタグで引き、SSM で応答する台を書き出す。人が目で確かめて要らない行を消す |
| 更新対象サーバーの一覧（定期更新） | 定期更新の関連付けの `Targets`（`tag:Environment = <環境>` と `tag:<用途タグ> = <値>` の**両方が付いた台**）。一覧は持たず、実行のたびに SSM が引く | `AWS::SSM::Association` の `Targets` | [cloudformation/scheduled-refresh.yml](cloudformation/scheduled-refresh.yml)（パラメータ `TagKey`・`TagValue`・`PurposeTagKey`・`PurposeTagValue`） |

どちらの一覧も、元は EC2 の**タグ**。手動の更新は環境のタグだけで引き（人が一覧を確かめる）、定期更新は環境のタグと用途タグの両方で決まる。定期更新に台を足す・外すときは、その台の用途タグを付ける・外す（次の予定からそのまま効く）。

ルールのデプロイ先にルールを上げるところ（`build-rules.sh`・`deploy-rules.sh`。手動か CodePipeline）は [親フォルダ](../README.md) で行う。このフォルダは、上がったルールを各サーバーに入れるところだけを受け持つ。

### 定期実行のスケジュール

![定期実行のスケジュール](refresh-schedule.svg)

毎週月曜・木曜の日本時間 9:00 に CodePipeline がルールを上げ、2 時間後の 11:00 に定期更新の関連付けが全台のルールを更新する。予定の式は UTC で書く。関連付けの cron 式は曜日を 1 つしか書けないので、月曜の分と木曜の分の 2 つにしている（[設計](scheduled-refresh-design.md#月曜と木曜で関連付けを-2-つにする理由)）。

### 定期実行時のエラーの定義と取り扱い

![定期更新のエラーの定義と取り扱い](failure-handling.svg)

| エラー（その台が `Failed` になるもの） | 段階 | 出力に出るもの | 主な原因 |
|---|---|---|---|
| S3 を読めない | 取得 | `aws s3 cp` のエラー（`403` など） | ルールの読み取りポリシーが付いていない、S3 に届く経路がない、ルールのデプロイ先にルールがない |
| 照合の値と合わない | 照合 | `PG blocked=checksum-mismatch` | ルールを上げている途中に取った |
| 入れ替えで止まる | ipset の入れ替え | ipset 入れ替えスクリプトのエラー | port-guard の初期設定の前（集合がない）、一覧の件数が下限未満 |
| AWS CLI がない | 取得の前 | `PG blocked=aws-cli-not-found` | 台に AWS CLI が入っていない |

| 取り扱い | 内容 |
|---|---|
| その台 | 何も変えずに止まる。ルールは前のままで、絞り込みは前の一覧で効き続ける |
| ほかの台 | 止めずに流し続ける（`MaxErrors: 100%`） |
| 記録（正本） | 関連付けの実行の履歴に、実行ごと・台ごとの結果が残る |
| 通知 | 失敗の通知の規則（`AWS::Events::Rule`）が、`EC2 State Manager Instance Association State Change` の `status: Failed` を拾い、SNS のトピックへ台ごとに 1 通送る（取りこぼすことがある） |
| 対処 | 次の予定で自動で流し直す。急ぐときは原因を直し、`refresh_rules.rb` でその台だけ流す（[instance-setup.md の運用](instance-setup.md#失敗した台を確かめる)） |

## 設定のステップ

各ステップのコマンドは [instance-setup.md](instance-setup.md) にある。

## IAM ロールと付けるポリシー

| ロール | 使う人・仕組み | 付けるポリシー | 種類 | 作り方・付け方 |
|---|---|---|---|---|
| 更新対象サーバーの IAM ロール（既存。インスタンスプロファイルのロール） | 各サーバー（SSM Agent と、ルールの更新スクリプトの `aws s3 cp`） | `AmazonSSMManagedInstanceCore` | AWS 管理ポリシー | 既に付いている前提（`docs/ec2/ssm-setup` で用意する。SSM で応答するのに要る） |
| 〃 | 〃 | `port-guard-rule-read-<環境>`（その環境のルールのデプロイ先の `s3:GetObject` だけ） | カスタマー管理ポリシー | [rule-read-policy.yml](cloudformation/rule-read-policy.yml) で作り、`aws iam attach-role-policy` で付ける（[instance-setup.md の 5](instance-setup.md#5-iam-ロールにルールの読み取りポリシーを付けるロールごと)） |
| 関連付けのロール `port-guard-refresh-rules-dispatch-<環境>` | State Manager（定期更新の関連付けがコマンドを送るとき） | `send-rule-refresh-document`（ルールの更新ドキュメントを EC2 のインスタンスに送る `ssm:SendCommand` だけ） | インラインポリシー（管理ポリシーは付けない） | [scheduled-refresh.yml](cloudformation/scheduled-refresh.yml) がロールごと作る |
| 失敗の通知の規則の実行ロール（名前はスタックが付ける） | EventBridge（失敗の通知の規則が SNS へ送るとき） | `publish-failures`（そのトピックへの `sns:Publish` だけ） | インラインポリシー | 同上（`NotificationTopicArn` を渡したときだけ）。トピックが KMS で暗号化されているなら、そのキーの権限を足す（要る操作は SNS のドキュメントで確かめる。今は入れていない） |

作業者（人・踏み台サーバー）の IAM ユーザー・ロールに付ける管理ポリシーは用意していない。要る権限は次のとおり（AWS のドキュメントで 1 つずつは確かめていない。足りなければ、エラーに出る操作を足す）。

| 作業 | 要る権限 |
|---|---|
| `list_instances.rb` | `ec2:DescribeInstances`、`ssm:DescribeInstanceInformation` |
| `refresh_rules.rb` | `sts:GetCallerIdentity`、`ssm:SendCommand`（ルールの更新ドキュメントと対象のインスタンス）、`ssm:ListCommands`、`ssm:ListCommandInvocations`、`ssm:GetCommandInvocation` |
| IAM ロールへのポリシーの付与（[instance-setup.md の 5](instance-setup.md#5-iam-ロールにルールの読み取りポリシーを付けるロールごと)） | `ec2:DescribeInstances`、`iam:GetInstanceProfile`、`iam:AttachRolePolicy` |
| スタックの作成・更新（[instance-setup.md の 1・2・7](instance-setup.md)） | CloudFormation のスタックの操作に加えて、スタックが作るもの（SSM のドキュメント・関連付け、IAM のポリシー・ロール、EventBridge の規則）を作る権限と、ロールを渡す `iam:PassRole` |
| 実行の履歴の確認（[instance-setup.md の 8](instance-setup.md#8-最初の予定のあとで確かめる環境ごとに-1-回)） | `ssm:ListAssociations`、`ssm:DescribeAssociationExecutions`、`ssm:DescribeAssociationExecutionTargets` |


## 手動の更新のコマンド

手順の中での使い方は [instance-setup.md の 6](instance-setup.md#6-手動で-1-回流して確かめる環境ごと)。

| コマンド | すること |
|---|---|
| `ruby rb/list_instances.rb --env <環境> [--tag-key KEY] [--tag-value VALUE] [--out FILE] [--overwrite]` | 環境のタグが合い、動いていて SSM で応答する台を、インスタンスの一覧ファイルに書き出す（読み取りだけ）。SSM で応答しない台は、外した理由とともに表示する。同じ名前のファイルがあれば上書きしない |
| `ruby rb/refresh_rules.rb --env <環境> [--list FILE] [--ipv6] [--s3-uri URI] [--document-name NAME]` | インスタンスの一覧ファイルの台に、ルールの更新ドキュメントを Run Command で流す。対象・取得元・ドキュメントを表示し、`y` を受けてから送る。1 台ずつ流し、1 台でも失敗したら残りは流さない。全台が `Success` なら終了コード 0 |

どちらも `--profile`・`--region` を受け付ける。取得元（ルールのデプロイ先）は `s3://ip-port-guard-rules-<アカウント ID>-<リージョン>-an/port-guard/<環境>/current`（親フォルダの `command/set-s3-uri.sh` と同じ組み立て方）。

インスタンスの一覧ファイルの例（タブ区切り。パブリック IP や Name タグがない台は `-`）:

```text
# 環境: staging（タグ Environment=staging）。2026-11-18 10:00:00 に list_instances.rb が作成
# instance_id	public_ip	name
i-0123456789abcdef0	203.0.113.10	web-staging-1
i-0fedcba9876543210	-	web-staging-2
```

## 決めたこと

| # | 決めたこと | 理由 |
|---|---|---|
| A1 | 取得・照合・ipset の入れ替えまでを 1 回で行う | 取得と入れ替えを分けると、取得だけ済んだ台が残る |
| A2 | 更新対象サーバーは、ルールのデプロイ先を**自分の IAM ロールの権限**で読む（ルールの読み取りポリシーを付ける） | ルールのデプロイ先バケットはパブリックアクセスをすべてブロックしている（[D9](../design-decisions.md#1-決めたこと)）。定期更新にもそのまま使える。暫定対応のフェーズ 1（`docs/ec2/ssm-setup`）の「既存のロールに権限を足さない」とは違う扱いになる |
| A3 | 手動の更新では、環境のタグで引いた一覧を人が目で確かめてから流す | 引いた結果をそのまま流さず、間に人の確認を挟む |
| A4 | インスタンスの一覧ファイルの列は、インスタンス ID・パブリック IP・Name タグ | 人が見て台を見分けられるようにする |
| A5 | AWS の操作は、gem を使わず、AWS CLI のコマンドを呼ぶ Ruby で書く（Ruby 2.6 以上・標準のライブラリだけ） | 作業者の PC と踏み台サーバーに gem を入れなくて済む |
| A6 | このフォルダの中で完結させる（`docs/ec2/ssm-setup` の部品は使わず、要るものは写す） | 親フォルダ（ip-port-guard-rule-refresh-pipeline）と同じく、このフォルダだけを写して運用できるようにする |
| A7 | ルールの更新スクリプトの正本は、ルールの更新ドキュメント（CloudFormation のテンプレート）だけにする。手動の更新も定期更新も、このドキュメントを流す（2026-11-19） | スクリプトが 1 か所になり、手動で確かめたものと同じものが定期更新で流れる |
| A8 | 定期更新は毎週月曜・木曜の日本時間 11:00（ルールのデプロイ先へのデプロイ 9:00 の 2 時間後）。全台に並列で流し、失敗した台は通知と実行の履歴で後から分かればよい（2026-11-18） | [設計](scheduled-refresh-design.md) |
| A9 | 呼び名は「ルールの更新」（refresh）。「適用」（apply）は使わない（2026-11-19。フォルダ・コマンド・ドキュメント・関連付け・スタックの名前も変えた） | 「適用」は、port-guard を最初に入れる初期設定（`install`・`enable`）と取り違えやすい。この仕組みは、入れ済みの台の ipset の集合の中身を入れ替えるだけ。親フォルダ（rule-refresh-pipeline）や ipset 入れ替えスクリプト（`refresh-ipv4.sh`）とも言葉がそろう |

## 決まっていないこと

| 項目 | 内容 |
|---|---|
| 環境のタグ | 実際のキーと値（既定の `Environment=<環境>` で合っているか） |
| 用途タグ | 定期更新に使う用途タグの実際のキーと値（仮の既定は `PortGuardScheduledRefresh` = `true`） |
| IPv6 | IPv6 も絞る台があるか（あれば手動は `--ipv6`、定期更新は `IncludeIpv6=1`） |
| どの環境で定期更新するか | 3 環境すべてか、`production` だけか |
| 通知に使うトピック | 親フォルダと同じトピックでよいか。KMS で暗号化されているか |
| 50 台を超える環境（手動の更新） | Run Command に 1 回で渡せるインスタンス ID は 50 まで。超えたら一覧ファイルを分けて流す |

## ファイル

| ファイル | 役割 |
|---|---|
| [instance-setup.md](instance-setup.md) | **インスタンスへの設定の手順**（1 つにまとめたもの） |
| [scheduled-refresh-design.md](scheduled-refresh-design.md) | 設計: ルールの定期更新（State Manager の関連付け。EventBridge Scheduler との比べ） |
| `cloudformation/rule-refresh-document.yml` | ルールの更新ドキュメント（アカウントに 1 つ。ルールの更新スクリプトの正本） |
| `cloudformation/rule-read-policy.yml` | ルールの読み取りポリシー（環境ごと） |
| `cloudformation/scheduled-refresh.yml` | 定期更新（環境ごと。定期更新の関連付け 2 つ、関連付けのロール、失敗の通知の規則） |
| `rb/list_instances.rb` | 手動の更新: 環境のタグで引き、インスタンスの一覧ファイルに書き出す（読み取りだけ） |
| `rb/refresh_rules.rb` | 手動の更新: インスタンスの一覧ファイルの台に、ルールの更新ドキュメントを Run Command で流す |
| `rb/lib/aws_cli.rb`・`rb/lib/cli.rb` | 汎用の部品（AWS CLI の呼び出し、オプション・確認・使い方の誤り）。`docs/ec2/ssm-setup/rb/lib/` から写した |
| `instance-lists/` | インスタンスの一覧ファイルの既定の置き場所（Git には入れない） |
| `system-architecture.svg`・`refresh-schedule.svg`・`failure-handling.svg` | 図: システムの構成、定期実行のスケジュール、定期実行時のエラーの定義と取り扱い（手で書いた SVG） |
| `setup-steps.svg` | 図: 設定のステップ（[instance-setup.md](instance-setup.md) の流れ） |
| `iam-policies.svg` | 図: IAM ロールと付けるポリシー（引き受ける相手・ロール・ポリシー・許す対象） |
