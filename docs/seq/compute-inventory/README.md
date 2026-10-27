# EC2・ECS・CodeBuild の棚卸し

EC2 インスタンス、ECS サービス、CodeBuild プロジェクトを、2 つの段階で棚卸しするツール。数百台の規模でも、運用中の環境に負荷をかけずに使えるようにしている。

1. **`snapshot`**: まとめて取得できる API だけを使って一覧を取る。台数が増えても、呼び出しはほとんど増えない。
2. **`detail`**: 一覧を jq で絞り込み、絞った分だけ、リソースごとの API で詳細を取る。

> **状態: 骨組み。** コマンドの形、段階どうしのつなぎ方、負荷を抑える仕組みはできている。一覧の項目は最小限で、今の `../ec2-inventory/` と `../ecs-inventory/` にある残りの項目は、まだ移していない。残りの作業は末尾の「この先の作業」を参照。

同じ動きをする実装を 3 つ置いている。

| 実装 | ファイル | 必要なもの |
|---|---|---|
| シェル | [`shell/compute-inventory.sh`](./shell/compute-inventory.sh) | bash, AWS CLI v2, jq |
| Ruby | [`ruby/compute_inventory.rb`](./ruby/compute_inventory.rb) | Ruby 3.0 以上, [`ruby/Gemfile`](./ruby/Gemfile) の gem |
| Python | [`python/compute_inventory.py`](./python/compute_inventory.py) | Python 3.9 以上, `boto3` |

## 使い方

```bash
# 1. 一覧を取る。取得の時点で範囲を絞ることもできる
./shell/compute-inventory.sh snapshot > snapshot.jsonl
./shell/compute-inventory.sh snapshot --ec2-filter Name=tag:env,Values=prod --cluster prod > snapshot.jsonl

# 2. 一覧を jq で絞り、その分だけ詳細を取る
jq -c 'select(.record_type == "ecs_service" and .cluster_name == "prod")' snapshot.jsonl \
  | ./shell/compute-inventory.sh detail --with task_definition,tasks,target_health > prod-services.jsonl

jq -c 'select(.record_type == "ec2_instance" and .tags.role == "web")' snapshot.jsonl \
  | ./shell/compute-inventory.sh detail --with target_health > web-health.jsonl
```

Ruby 版と Python 版も、コマンドとオプションは同じ（`bundle exec ruby ruby/compute_inventory.rb snapshot`、`python/compute_inventory.py snapshot` など）。対象のアカウントとリージョンは `AWS_PROFILE` と `AWS_REGION` で決まる。

### `snapshot` のオプション

| オプション | 内容 |
|---|---|
| `--ec2-filter Name=...,Values=...` | EC2 の取得を AWS 側で絞る。書き方は AWS CLI の `--filters` と同じ（例: `Name=tag:env,Values=prod`、`Name=vpc-id,Values=vpc-0123`）。何回でも指定できる |
| `--cluster NAME` | ECS を指定したクラスターだけにする。何回でも指定できる。指定しなければすべてのクラスター |

### `detail` のオプション

| オプション | 既定 | 内容 |
|---|---|---|
| `--with KIND,...` | （必須） | 取る詳細の種類。下の表を参照 |
| `--interval SEC` | `0.2` | 詳細を取る API 呼び出しの間隔（秒） |
| `--max N` | `100` | 入力の件数の上限。超えたら、絞り込み忘れとみなして何もせずに止まる |

| 種類 | 対象 | 取るもの | 呼び出し |
|---|---|---|---|
| `task_definition` | `ecs_service` | タスク定義（OS、アーキテクチャ、CPU / メモリ、コンテナとイメージ） | タスク定義 1 種類につき 1 回。同じものは 1 回しか引かない |
| `tasks` | `ecs_service` | 動いているタスクと、そのホスト（コンテナインスタンス）、タスク定義のリビジョン | サービスごとに `ListTasks` と、100 タスクにつき 1 回の `DescribeTasks` |
| `target_health` | `ecs_service`, `ec2_instance` | ターゲットグループでのヘルス | ターゲットグループ 1 つにつき 1 回。同じものは 1 回しか引かない。`ec2_instance` では、どこに登録されているかわからないので、すべてのターゲットグループを 1 回ずつ見る |

`detail` の出力は、入力のレコードに `details_collected_at` と `details`（種類 → 結果）を足したもの。取れなかった種類は `details` の値が `null` になり、その理由が `errors` に足される。

## 負荷を抑える仕組み

- **`snapshot` は、リソースごとの呼び出しをしない。** 500 台なら、EC2 の呼び出しは 15 回ほどになる。内訳は DescribeInstances が 1 回、AMI 100 種類ごとの DescribeImages、SSM の 50 台ごとのページ。ECS は、クラスターごとの List と、10〜100 件ずつまとめた Describe だけ。CodeBuild は、ListProjects と、100 プロジェクトごとの BatchGetProjects だけ。
- **`detail` は 1 件ずつ順に処理し、呼び出しの間に `--interval` 秒の間隔を空ける。** 並列には呼ばない。
- **同じリソースは 1 回の実行で 1 回しか引かない。** タスク定義やターゲットグループのヘルスは、複数のレコードから参照されていても使い回す。
- **再試行は adaptive にしている。** スロットリングされたときは、SDK と CLI が自分で送る速さを落とす。
- **`--max` を超える入力は処理しない。** 一覧を丸ごと流してしまう事故を防ぐ。

## 出力のレコード（骨組みの時点）

どのレコードにも `record_type`、`account_id`、`region`、`collected_at`、`errors` が入る。

**`ec2_instance`**（1 インスタンス 1 行）: `instance_id`、`state`、`instance_type`、`architecture`、`base_os`、`base_os_source`、`image_id`、`launch_time`、`tags`、`ecs`

- **`ecs`:** インスタンスが ECS のコンテナインスタンス（ホスト）なら、`{cluster_name, container_instance_arn, status, agent_connected, agent_version}` が入る。ホストでなければ `null`。EC2 と ECS を突き合わせる必要はない。
- **`tags`:** `Name` 以外のタグ。インスタンス名（`Name` タグ）は出さない。
- **`ecs` の範囲:** `--cluster` を指定したときは、指定したクラスターのホストだけに値が入る。
- **ベース OS:** 判定の仕方は `../ec2-inventory/README.md` と同じ。SSM の報告 → AMI 名（[`ami-os-patterns.json`](./ami-os-patterns.json)）→ `PlatformDetails` の順に見る。

**`ecs_service`**（1 サービス 1 行）: `cluster_name`、`service_name`、`service_arn`、`status`、`launch_type`、`desired_count`、`running_count`、`task_definition`、`load_balancers`

**`codebuild_project`**（1 プロジェクト 1 行）: プロジェクトの定義（`BatchGetProjects`）から作る。ビルドの履歴は含まない。

| 項目 | 内容 |
|---|---|
| `project_name` / `project_arn` / `description` | プロジェクト名・ARN・説明 |
| `environment_type` | ビルド環境の種類（`LINUX_CONTAINER`、`ARM_CONTAINER`、`WINDOWS_SERVER_2019_CONTAINER`、`LINUX_LAMBDA_CONTAINER` など） |
| `image` | ビルド環境のイメージ（例: `aws/codebuild/amazonlinux2-x86_64-standard:5.0`、ECR のイメージ） |
| `base_os` | ベース OS（下の「CodeBuild のベース OS の判定」を参照） |
| `compute_type` | コンピューティングの大きさ（`BUILD_GENERAL1_SMALL` など） |
| `privileged_mode` | 特権モード（ビルドの中で Docker を動かすときに有効にする）が有効か |
| `image_pull_credentials_type` | イメージを取得する認証（`CODEBUILD` / `SERVICE_ROLE`） |
| `service_role` | サービスロールの ARN |
| `source_type` / `source_location` / `source_version` | ソースの種類（`GITHUB`、`CODECOMMIT`、`S3`、`CODEPIPELINE`、`NO_SOURCE` など）・場所・ブランチやコミット |
| `webhook` | Webhook でビルドを始める設定があれば `{build_type, filter_group_count}`、なければ `null` |
| `vpc` | VPC の中でビルドするなら `{vpc_id, subnets, security_group_ids}`、しないなら `null` |
| `timeout_in_minutes` / `queued_timeout_in_minutes` | ビルドのタイムアウトと、キューで待つ時間の上限（分） |
| `concurrent_build_limit` | 同時に動かせるビルドの数の上限。設定していなければ `null` |
| `artifacts_type` / `cache_type` | 成果物の置き場所とキャッシュの種類 |
| `cloudwatch_logs` / `s3_logs` | ログの出力先ごとの有効・無効（`ENABLED` / `DISABLED`） |
| `encryption_key` | 成果物を暗号化する KMS キー |
| `created_at` / `last_modified_at` | 作成日時と最終更新日時 |
| `tags` | タグ（キー → 値） |

環境変数は、名前も値も出さない。

#### CodeBuild のベース OS の判定

CodeBuild が提供するイメージ（`aws/codebuild/` で始まるもの）は、イメージ名を [`codebuild-image-os.json`](./codebuild-image-os.json) の正規表現に上から順に当てて OS を決める。

| `base_os` | 条件 |
|---|---|
| 対応表の OS（`Amazon Linux 2023`、`Ubuntu 22.04` など） | 対応表のどれかに一致した |
| `Unknown` | `aws/codebuild/` で始まるが、対応表に無い。対応表への追記が要る |
| `Custom Image` | ECR などの自前のイメージ。OS はイメージの中身で決まるので、このツールでは判定できない |

`codebuild-image-os.json` は、AWS ドキュメントの「CodeBuild に用意されている Docker イメージ」の表に合わせて手で更新する。Lambda コンピューティング用のイメージ（`*-lambda-standard:*`）はまだ載せていないので、`Unknown` になる。

## 必要な IAM 権限

- `snapshot`: `ec2:DescribeInstances`、`ec2:DescribeImages`、`ssm:DescribeInstanceInformation`、`ecs:ListClusters`、`ecs:ListServices`、`ecs:DescribeServices`、`ecs:ListContainerInstances`、`ecs:DescribeContainerInstances`、`codebuild:ListProjects`、`codebuild:BatchGetProjects`
- `detail`: `ecs:DescribeTaskDefinition`、`ecs:ListTasks`、`ecs:DescribeTasks`、`elasticloadbalancing:DescribeTargetGroups`、`elasticloadbalancing:DescribeTargetHealth`

## この先の作業

- [ ] `snapshot` の項目を、`../ec2-inventory/` と `../ecs-inventory/` から移す（AMI の詳細、IMDS、SSM の状態、ネットワーク、起動テンプレート、ECS の起動タイプの詳細、ネットワーク、サーキットブレーカーなど）。EC2 のインスタンス名（`Name` タグ）と、ECS のコンテナの環境変数名・シークレット名は移さない
- [ ] `detail` の `task_definition` の項目を、`../ecs-inventory/` のタスク定義の項目にそろえる
- [ ] `detail` の `tasks` で、コンテナインスタンスの ARN を EC2 インスタンス ID に結び付ける（`snapshot` の `ecs.container_instance_arn` と突き合わせる例を書くか、`detail` 側で引くかを決める）
- [ ] `detail` を中断したときに続きから再開する（`--skip-done 出力ファイル`。済んだレコードを `instance_id` / `service_arn` で飛ばす）
- [ ] CodeBuild の `snapshot` を絞り込むオプション（`--ec2-filter` / `--cluster` に当たるもの）と、`detail` の種類（直近のビルドの結果など）が要るかを決める
- [ ] 実際の AWS 環境での動作確認と、3 つの実装の出力がそろうことの確認
- [ ] 移し終えたら `../ec2-inventory/` と `../ecs-inventory/` を削除し、`../README.md` を更新する
