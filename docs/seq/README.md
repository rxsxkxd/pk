# AWS リソースの棚卸しツール

AWS アカウントの 1 リージョンにあるリソースを一覧にし、1 件 1 行の JSON（JSONL）で出力するツール群。サービスごとに 1 つのツールに分けている。OS やランタイムの更新計画、設定の点検、どこから呼ばれているかの調査に使う。

数百台の規模の環境でも負荷をかけないよう、どのツールも「一覧取得」と「詳細取得」の 2 段階で使う。

## 用語

| 用語 | 意味 |
|---|---|
| **一覧取得**（`snapshot`） | まとめて取得できる API だけを使って一覧を取る段階。リソースの数が増えても、API の呼び出しはほとんど増えない |
| **詳細取得**（`detail`） | 一覧取得の結果を jq で絞り込み、絞った分だけ、リソースごとの API で詳細を足す段階 |
| **レコード** | 出力の 1 行。`record_type` で種類（`ec2_instance`、`s3_bucket` など）を見分ける |
| **詳細の種類** | 詳細取得で取るものの名前（`volumes`、`security` など）。`--with` で指定する |
| **シェル版** | bash から `aws` コマンド（AWS CLI）を呼ぶ実装 |
| **Ruby SDK 版 / Python SDK 版** | AWS SDK（aws-sdk の gem / boto3）を使う実装 |
| **Ruby CLI 版 / Python CLI 版** | Ruby / Python から `aws` コマンドを子プロセスとして呼ぶ実装。標準ライブラリだけで動く |

## ツールの一覧

並びは [`awsdocs/README.md`](./awsdocs/README.md) の章立てに合わせている。各ツールの `README.md` に使い方、`DATA.md` に結果データの説明がある。

| 分類 | ツール | レコードの種類 | 詳細の種類 |
|---|---|---|---|
| 処理を動かす・データを持つ | [`ec2-inventory/`](./ec2-inventory/README.md) | `ec2_instance` | `volumes`、`target_health` |
| | [`ecs-inventory/`](./ecs-inventory/README.md) | `ecs_service`、`ecs_container_instance` | `task_definition`、`tasks` |
| | [`fargate-inventory/`](./fargate-inventory/README.md) | `fargate_task` | `task_definition` |
| | [`rds-inventory/`](./rds-inventory/README.md) | `rds_db_instance`、`rds_db_cluster` | `parameters` |
| | [`s3-inventory/`](./s3-inventory/README.md) | `s3_bucket` | `security`、`management`、`tags` |
| ネットワークの区画と通信の制御 | [`vpc-inventory/`](./vpc-inventory/README.md) | `vpc` | `flow_logs` |
| | [`subnet-inventory/`](./subnet-inventory/README.md) | `subnet` | `network_interfaces` |
| | [`security-group-inventory/`](./security-group-inventory/README.md) | `security_group` | `network_interfaces` |
| サーバーレスとメッセージ | [`lambda-inventory/`](./lambda-inventory/README.md) | `lambda_function` | `policy` |
| | [`apigateway-inventory/`](./apigateway-inventory/README.md) | `apigateway_rest_api`、`apigateway_v2_api` | `stages`、`routes` |
| | [`sns-inventory/`](./sns-inventory/README.md) | `sns_topic` | `attributes`、`tags` |
| | [`sqs-inventory/`](./sqs-inventory/README.md) | `sqs_queue` | `attributes`、`tags` |
| 入口での配信・負荷分散・攻撃の遮断 | [`cloudfront-inventory/`](./cloudfront-inventory/README.md) | `cloudfront_distribution` | `config`、`tags` |
| | [`alb-inventory/`](./alb-inventory/README.md) | `elbv2_load_balancer`、`elbv2_target_group` | `listeners`、`attributes`、`target_health` |
| | [`waf-inventory/`](./waf-inventory/README.md) | `wafv2_web_acl` | `rules`、`resources`、`logging` |
| ビルド | [`codebuild-inventory/`](./codebuild-inventory/README.md) | `codebuild_project` | `last_build` |

各サービスの一覧取得・詳細取得に使える CLI コマンドの全体は [`aws-cli-config-inventory.md`](./aws-cli-config-inventory.md) にまとめている。

## 使い方の流れ

```bash
# 1. 一覧取得。対象のアカウントとリージョンは AWS_PROFILE と AWS_REGION で決まる
AWS_PROFILE=prod AWS_REGION=ap-northeast-1 ./ec2-inventory/shell/ec2-inventory.sh snapshot > ec2.jsonl

# 2. jq で絞り込み、その分だけ詳細取得
jq -c 'select(.tags.env == "prod")' ec2.jsonl | ./ec2-inventory/shell/ec2-inventory.sh detail --with volumes > ec2-prod.jsonl
```

### 詳細取得の共通のオプション

| オプション | 既定 | 内容 |
|---|---|---|
| `--with KIND,...` | （必須） | 取る詳細の種類。当てはまらない種類のレコードには何もしない |
| `--interval SEC` | `0.2` | 詳細取得の API 呼び出しの間隔（秒） |
| `--max N` | `100` | 入力の件数の上限。超えたら、絞り込み忘れとみなして何もせずに止まる |

## 共通の方針

- **読み取りだけ。** List / Describe / Get 系の API しか呼ばない。
- **負荷を抑える。**
  - 一覧取得では、まとめて取得できる API（ページ送り、100 件ずつの Describe など）だけを使う。
  - 詳細取得では、1 件ずつ順に処理し、呼び出しの間を空ける。同じリソース（タスク定義、ターゲットグループのヘルスなど）は、1 回の実行で 1 回しか引かない。
  - 再試行は adaptive にしているので、スロットリングされたときは CLI と SDK が自分で送る速さを落とす。
- **秘密情報は出さない。** 環境変数の値やシークレットは出さない（Lambda だけ、環境変数の名前を出す）。SNS のメールと SMS の宛先も出さない。
- **失敗は黙って捨てない。** 個々の取得に失敗したものは、そのレコードの `errors` に `{operation, code, message}` として残す。一覧そのものが取れないときは、結果が不完全になるので止まる。
- **「設定が無い」はエラーにしない。** S3 のバケットポリシーが無いなど、設定が無いことをエラーで返す API は、`null` などの値として扱う。
- **5 つの実装で出力をそろえる。** 項目の名前と順番は同じ。日時は UTC の `YYYY-MM-DDTHH:MM:SSZ` にそろえる。

## フォルダ構成と共通部分

```
docs/seq/
├── README.md                # このファイル
├── sync-common.sh           # 共通部分を各ツールに写すスクリプト
├── _common/                 # 共通部分の正本
│   ├── shell/lib.sh             # シェル版の共通部分
│   ├── ruby/sdk/inventory_common.rb
│   ├── ruby/cli/inventory_common.rb
│   ├── ruby/entry.rb            # Ruby の入口（ツールごとの名前で写す）
│   ├── python/inventory_common.py
│   ├── python/sdk/aws_client.py # boto3 で呼ぶ部分
│   ├── python/cli/aws_client.py # aws コマンドで呼ぶ部分
│   └── python/entry.py          # Python の入口
├── <サービス>-inventory/
│   ├── README.md / DATA.md
│   ├── tables/                  # 対応表（あるツールだけ）
│   ├── shell/<ツール>.sh
│   ├── ruby/sdk/  ruby/cli/     # service.rb（サービスごとの処理）と、写した共通部分
│   └── python/sdk/  python/cli/ # service.py（SDK 版と CLI 版で同じもの）と、写した共通部分
├── aws-cli-config-inventory.md  # CLI コマンド集
└── awsdocs/                     # AWS の各サービスの解説（一時的な資料）
```

各実装のディレクトリは、それだけを持っていけば動くように、共通部分を写して置いている。共通部分は `_common/` が正本なので、直すときは `_common/` を直してから写す。

```bash
./sync-common.sh          # 写す
./sync-common.sh --check  # 写さずに、正本と違うファイルを報告する（違いがあれば終了コード 1）
```

同じスクリプトが、Python の `python/sdk/service.py` を `python/cli/service.py` に、各ツールの `tables/` を各実装のディレクトリに写す。Ruby の `service.rb` は、SDK 版と CLI 版で応答の形が違うので別々に書いている。

## 確認の状況

- 5 つの実装すべてで構文チェックをしている。
- シェル版の jq は、空の応答を返す偽の `aws` コマンドで一覧取得とすべての詳細取得を通し、構文エラーが無いことを確認している。
- 実際の AWS 環境での動作と、5 つの実装の出力がそろうことは、まだ確認していない。
