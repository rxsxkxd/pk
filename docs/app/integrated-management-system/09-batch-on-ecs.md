# バッチの実行基盤（ECS を中心にした AWS の定番構成）

> 位置づけ: **検討中のメモ**である。現状のバッチがどの仕組みで動いているかは未調査（Q6）。調査の観点は末尾にまとめた。処理の中身の設計（fan-out、冪等性）は [04-batch-design.md](04-batch-design.md)。

## 結論

AWS でバッチをコンテナで動かすときの定番は、次の組み合わせである。

| 役割 | サービス |
|---|---|
| いつ動かすか（スケジュール） | **EventBridge Scheduler** |
| 処理の流れ（順序、分岐、テナントごとの並列、再試行、失敗時の通知） | **Step Functions** |
| 処理そのもの | **ECS on Fargate のタスク**（サーバーの管理が不要） |
| コンテナイメージ | **ECR** |
| DB の認証情報 | **Secrets Manager**（または SSM Parameter Store） |
| ログ・監視 | **CloudWatch Logs／アラーム**、失敗時は **SNS** で通知 |
| 定義の管理 | **CDK／CloudFormation／Terraform**（IaC） |

統合管理システムの Rails アプリと**同じコンテナイメージ**を使い、起動コマンドだけを変えて（`bin/rails runner ...` や `bin/rake ...`）バッチとして動かせる。既存のモデルとロジックをそのまま使えるのが利点である。

## 構成図

```
EventBridge Scheduler（cron 式、タイムゾーン指定可）
   │
   ▼
Step Functions（ステートマシン）
   ├─ 1. 対象テナントの一覧を作る（ECS タスク or Lambda）
   │
   ├─ 2. Map ステート：テナントごとに並列実行（MaxConcurrency で同時実行数を制限）
   │      └─ ECS RunTask（Fargate, .sync で完了まで待つ）
   │            コマンド: bin/rails runner Batch::X.run(tenant: "acme", run_id: ...)
   │            Retry: 一時的な失敗は自動で再試行
   │            Catch: 失敗したテナントを記録して続行
   │
   ├─ 3. 集約：成功／失敗の一覧を作る
   │
   └─ 4. 失敗があれば SNS で通知
```

- Step Functions の実行履歴に、**どのテナントがいつ成功・失敗したか**が残る。再実行も失敗分だけを対象にできる。
- テナントが数百件程度なら通常の Map で足りる。数千件以上や、S3 上の大きな一覧を入力にする場合は **Distributed Map** を使う。
- RDS インスタンス単位で同時実行数を制御したい場合は、一覧をインスタンスごとにまとめ、外側の Map でインスタンス、内側の Map でテナントを回し、内側の `MaxConcurrency` で絞る。

## 処理の形ごとの使い分け

| 処理の形 | 構成 |
|---|---|
| 単発の定期処理（順序や分岐がない） | EventBridge Scheduler → ECS RunTask を直接起動（Step Functions なし） |
| **テナントごとの並列処理、複数の手順、失敗時の扱いがある** | **EventBridge Scheduler → Step Functions → ECS RunTask**（上の構成） |
| イベントやキューを契機に常時処理する（[08](08-data-sync-options.md) の S3 の取り込みワーカーなど） | **ECS サービス**（常駐）が SQS／Kinesis を読む。キューの滞留数でタスク数を自動増減する |
| 計算量が大きく、大量のジョブを捌く（配列ジョブ、優先度付きのキュー） | AWS Batch（Fargate または EC2）。業務バッチでは Step Functions＋ECS のほうが一般的 |
| 15 分以内で終わる軽い処理 | Lambda も可。ただし DB への接続数と VPC 内の配置に注意 |

## ECS タスクの設計の要点

- **ネットワーク**: プライベートサブネットに配置し、セキュリティグループで RDS への接続を許可する。ECR や Secrets Manager へは VPC エンドポイントか NAT 経由で到達させる。
- **権限**: タスクロールに必要最小限の権限だけを付ける（Secrets Manager の読み取り、S3 への書き出しなど）。
- **認証情報**: DB のパスワードは Secrets Manager に置き、タスク定義の `secrets` で環境変数として渡す。イメージやタスク定義に直接書かない。
- **接続数**: タスクを並列に起動すると DB への接続が増える。`MaxConcurrency` で上限を決め、必要なら RDS Proxy を入れる（[04](04-batch-design.md)）。
- **費用**: 中断されても再実行できるバッチなら、Fargate Spot で費用を下げられる。
- **終了コード**: 成功は 0、失敗は 0 以外で終わるようにする。Step Functions はこれで成否を判定する。
- **ログ**: 標準出力に出せば CloudWatch Logs に集まる。テナント ID と実行 ID を必ずログに含める。

## 今の Rails のままで ECS に載せる場合

- 統合管理システムがすでにコンテナで動いていれば、同じイメージをそのまま使える。動いていなければ、まず **Dockerfile を用意してコンテナ化する**ことが最初の作業になる。
- バッチの入口を「テナント ID と実行 ID を引数に取る 1 つのコマンド」に揃える（例: `bin/rails runner 'Batch::X.run(tenant: ARGV[0], run_id: ARGV[1])'`）。
- Rails 5 と古い Ruby のイメージは、ベースイメージのセキュリティ更新が受けられない点に注意する（[06](06-platform-options.md)）。

## 現状のバッチの調査の観点（Q6）

統合管理システムのリポジトリと、動いているサーバーで次を確認する。

| 確認する場所 | 分かること |
|---|---|
| `Gemfile` の `whenever`・`sidekiq`・`sidekiq-cron`・`sidekiq-scheduler`・`resque`・`delayed_job`・`clockwork` | どの仕組みでスケジュール・非同期処理をしているか |
| `config/schedule.rb`（whenever）、`config/sidekiq.yml`、`config/clock.rb` | 実行スケジュール |
| `lib/tasks/*.rake`、`app/jobs/`、`app/workers/` | バッチの入口と処理の中身 |
| サーバーの `crontab -l`、`/etc/cron.d/` | OS の cron から直接起動しているか |
| ECS のスケジュールタスク、EventBridge のルール、Jenkins などの CI ツール | AWS や外部ツールから起動しているか |
| 各バッチの実行時間、頻度、失敗時の対応手順（手作業の再実行など） | 移行後に満たすべき要件 |

調査の結果を、バッチごとに「入口のコマンド」「スケジュール」「対象テナント（指定／全件）」「書き戻しの有無」「実行時間」の一覧にまとめると、移行先の構成（上の使い分け）を決めやすい。
