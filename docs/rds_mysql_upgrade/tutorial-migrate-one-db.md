# チュートリアル: 1 つの DB を MySQL 8.0 から 8.4 へ移行する

RDS for MySQL 8.0 の DB インスタンス 1 つを、Blue/Green Deployments で MySQL 8.4 へ移行する手順です。作業は次の 4 ステップです。

| ステップ | やること | どこで |
|---|---|---|
| 1 | 成立条件チェックを実行し、結果を確認する | 手元の端末 |
| 2 | パイプラインを起動し、Green（8.4 の新しい DB）を作る | AWS コンソール または AWS CLI |
| 3 | Green の検証レポートを確認する | AWS コンソール または AWS CLI |
| 4 | 切り替える（Switchover） | AWS コンソール または AWS CLI |

各ステップの終わりに「次へ進んでよいか」の確認があります。**確認が取れないまま次のステップへ進まないでください。**

## 始める前に

次がそろっていることを確認してください。

- **パイプラインが作成済みであること**（環境ごとに 1 本。例: `rds-bg-staging`）。まだなら [環境構築](operations-environment-setup.md) を先に行います
- **8.4 用の DB パラメータグループが作成済みであること**。共通のものを事前に作成してある前提で、このチュートリアルでは扱いません
- **対象の DB が設定ファイルに書かれていること**。設定ファイル（`config/blue-green/<環境>.yml`。例: `staging.yml`）は、設定を管理しているリポジトリにあります。この中のサービス名（例: `example-service`）を使います
- 手元の端末に **AWS CLI v2** と **Go 1.25 以上** があり、対象の AWS アカウントへ読み取りでアクセスできること

以下の例では、環境を `staging`、サービス名を `example-service`、移行する DB を `example-service-staging-mysql80`、リージョンを `ap-northeast-1` とします。自分の値に読み替えてください。

---

## ステップ 1: 成立条件チェック

移行する DB が Blue/Green Deployments の条件を満たしているかを調べます。**AWS の情報を読むだけで、何も変更しません。**

### 1-1. 情報を集める

このリポジトリのルートで実行します。

```bash
export AWS_PROFILE=<対象アカウントのプロファイル>
OUT=work/prereqs-example-service-staging

go run ./tools/collect_blue_green_prereqs \
  --db-instance-id example-service-staging-mysql80 \
  --region ap-northeast-1 \
  --output-dir "$OUT"
```

### 1-2. 判定してレポートを作る

```bash
go run ./tools/evaluate_blue_green_prereqs --input-dir "$OUT"
```

画面に項目ごとの判定が出て、最後にレポートの場所が表示されます（`$OUT/prereqs-evaluation-report.md`）。

```
PASS     0-1-01 自動バックアップ                BackupRetentionPeriod=7
REVIEW   0-1-02 binlog_format           MIXED（...）
...
結果: STOP=0, REVIEW=2
Report: work/prereqs-example-service-staging/prereqs-evaluation-report.md
```

### 1-3. 結果を確認する

| 判定 | 意味 | どうするか |
|---|---|---|
| `PASS` | 条件を満たしている | 何もしない |
| `REVIEW` | 自動では判断できない。人が確かめる | レポートで内容を確認し、問題ないかを判断する |
| `STOP` | このままでは移行できない | **原因を解消してからやり直す**。レポートの「補足事項」に対処が書いてある |

> **補足**: AWS からは見えない項目（外部のレプリケーション、InnoDB 以外のテーブル、MySQL のアップグレードチェッカー）は、DB へ接続して集めると自動で判定されます。集めていない場合は `REVIEW`（未収集）になるので、手で確かめるか、[ツールの使い方](tools/README.md) の「MySQL 側の収集」で集めてから 1-2 をやり直してください。

**✅ 次へ進んでよい条件**: `STOP` が 0 件で、`REVIEW` をすべて確認し終えていること。

---

## ステップ 2: パイプラインで Green を作る

パイプラインが、元の DB（Blue）の保護スナップショットを取り、8.4 の新しい DB（Green）を作ります。そのまま Green の検証まで行います。**本番の DB は切り替わりません。**

### 2-1. 構築を許可する

設定ファイル（`config/blue-green/staging.yml`）の対象サービスで、`actions.build` を `approved` に変えます。**`switchover` は `pending` のままにしてください。**

```yaml
    actions:
      build: approved
      switchover: pending
```

変更をコミットし、パイプラインが読むリポジトリへ push します。**パイプラインはリポジトリの内容を読むので、push を忘れると何も起きません。**

### 2-2. パイプラインを起動する

**AWS コンソールの場合**

1. CodePipeline を開き、パイプライン `rds-bg-staging` を選ぶ
2. 「変更をリリースする」（Release change）を押す
3. 変数 `ServiceName` に `example-service` を入れて開始する

**AWS CLI の場合**

```bash
aws codepipeline start-pipeline-execution \
  --name rds-bg-staging \
  --variables name=ServiceName,value=example-service
```

### 2-3. 終わるまで待つ

パイプラインは次の順に進みます。Green の作成は DB の大きさによって数十分〜1 時間程度かかります。

```
Source → Prepare → BuildGreen → VerifyGreen → Switchover（今回はスキップ）
```

`Switchover` が「スキップ」になって、パイプラインが成功で終われば完了です。`switchover: pending` なので、切替の承認ボタンは表示されません。

**✅ 次へ進んでよい条件**: `BuildGreen` と `VerifyGreen` が成功していること。どちらかが失敗した場合は、そのアクションの「詳細」からログを開き、表示された理由を確認してください（`VerifyGreen` の失敗は、Green が設定と違っているという意味です。ステップ 3 のレポートに理由が出ます）。

---

## ステップ 3: Green の検証レポートを確認する

`VerifyGreen` が作ったレポート（`green-verification-report.md`）を開き、Green に切り替えてよいかを判断します。

### 3-1. レポートを取り出す

**AWS コンソールの場合**

1. パイプラインの実行画面で、`VerifyGreen` アクションの「詳細」を押す（CodeBuild のビルド画面が開く）
2. 「アーティファクト」の場所（S3）を開き、zip をダウンロードする
3. zip の中の `artifacts/green-verification-report.md` を開く

**AWS CLI の場合**

```bash
# 最新の VerifyGreen のビルドから、成果物の場所を調べる
BUILD_ID=$(aws codebuild list-builds-for-project \
  --project-name rds-bg-staging-verify-green --query 'ids[0]' --output text)
LOCATION=$(aws codebuild batch-get-builds --ids "$BUILD_ID" \
  --query 'builds[0].artifacts.location' --output text)

# arn:aws:s3:::<バケット>/<パス> を s3://<バケット>/<パス> にして取り出す
aws s3 cp "s3://${LOCATION#arn:aws:s3:::}" verify-green.zip
unzip -o verify-green.zip -d verify-green
open verify-green/artifacts/green-verification-report.md   # macOS の場合
```

### 3-2. 確認する

レポートの先頭の **「0. 検証結果」** に、自動で突き合わせた結果が出ます。`VerifyGreen` が成功していれば、ここはすべて適合しています。

| 自動で確かめていること | 内容 |
|---|---|
| エンジンバージョン | 8.4 になっている |
| インスタンスクラス | 設定どおり |
| パラメータグループ | 8.4 用のものが付いていて、適用済み（`in-sync`） |
| レプリカ遅延 | 0 秒（Blue の変更が Green に追いついている） |

そのうえで、人が次を確認します。

- **パラメータの値**: 8.4 用パラメータグループの宣言値どおりに適用されているか（「差異」が無いか）
- **アプリケーションの確認**: 必要に応じて、Green に接続して動作を確かめる（Green のエンドポイントはレポートと RDS コンソールに出ています）

**✅ 次へ進んでよい条件**: レポートに問題が無く、切り替えてよいと判断したこと。

> **切替は元に戻すのが難しい作業です。**切り替えると、元の DB（Blue）は名前の末尾に `-old1` が付いて残りますが、元へ戻すには別の作業が必要になります。ここが最後の確認です。

---

## ステップ 4: 切り替える（Switchover）

本番の接続先を Green へ切り替えます。**本番に影響する作業です。**切り替えている間（通常は 1 分程度）、DB への書き込みが止まります。利用者への周知や作業時間帯を決めてから行ってください。

### 4-1. 切替を許可する

設定ファイルの対象サービスで、`actions.switchover` を `approved` に変えて、コミット・push します。

```yaml
    actions:
      build: approved
      switchover: approved
```

### 4-2. パイプラインを起動する

ステップ 2-2 と同じ方法で、もう一度パイプラインを起動します。`BuildGreen` は作成済みの Green を見つけて何もせずに進み、`VerifyGreen` がもう一度検証します。

### 4-3. 承認する

`Switchover` ステージで**手動承認**が表示されます。ステップ 3 のレポートをもう一度見て、問題が無ければ承認します。

**AWS コンソールの場合**: `Switchover` ステージの「確認」（Review）を押し、「承認」を選んで送信します。

**AWS CLI の場合**

```bash
TOKEN=$(aws codepipeline get-pipeline-state --name rds-bg-staging \
  --query "stageStates[?stageName=='Switchover'].actionStates[0].latestExecution.token" --output text)
aws codepipeline put-approval-result \
  --pipeline-name rds-bg-staging --stage-name Switchover --action-name ManualApproval \
  --token "$TOKEN" --result summary="検証レポートを確認した",status=Approved
```

承認すると切替が始まり、完了するまでパイプラインが待ちます。

**✅ 完了の確認**: `Switchover` ステージが成功していること。RDS コンソールで、元の名前（`example-service-staging-mysql80`）の DB が MySQL 8.4 になっていれば完了です。アプリケーションは接続先を変えずに、そのまま 8.4 の DB へつながります。

---

## 切り替えた後

- しばらくの間（週次・月次の処理が一通り終わるまでを目安に）、アプリケーションと DB の監視を続けてください
- 元の DB（`-old1` が付いたもの）は残っています。削除（後始末）は、切り戻しが不要だと判断してから別の手順で行います（[移行の実行](operations-migration-run.md) の「後始末」）。**削除するまで、元の DB の料金がかかり続けます**

## うまくいかないとき

| 症状 | 原因と対処 |
|---|---|
| パイプラインを起動しても Green が作られない（`BuildGreen` がすぐ終わる） | 設定の `build` が `approved` になっていないか、push されていない |
| `Prepare` で失敗する | 8.4 用パラメータグループが無いか、設定ファイルの名前と違う（`PrecheckParameterGroup` のログを見る） |
| `BuildGreen` が「使えない状態の Deployment がある」で止まる | 以前に失敗した Blue/Green Deployment が残っている。RDS コンソールで内容を確認し、不要なら削除してからやり直す |
| `VerifyGreen` が失敗する | Green が設定と違う。ステップ 3 のレポートの「0. 検証結果」に理由が出る |
| `Switchover` の承認が表示されない | 設定の `switchover` が `approved` になっていないか、push されていない |
| 切替がタイムアウトで失敗する | 書き込みが多い時間帯は切替が終わりにくい。時間帯を変えてやり直す |

細かい仕組みや各ステージの詳細は、[移行の実行](operations-migration-run.md) を参照してください。
