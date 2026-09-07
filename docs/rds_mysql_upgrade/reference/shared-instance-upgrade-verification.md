# 同居構成（ステージと本番が同一インスタンス）の移行手順

## 対象と前提

ステージ環境と本番環境が**同一の RDS インスタンス上に別データベースとして同居**している構成を対象とする。インスタンスが分かれている構成は本書の対象外であり、通常どおり「ステージの更新 → ステージの検証 → 本番の更新 → 本番の検証」の順で進められる。

```
共有インスタンス（MySQL 8.0）
  ├─ staging_db     ← ステージ
  └─ production_db  ← 本番
```

## なぜ通常の手順が使えないのか

**Blue/Green Deployment はインスタンス単位の仕組みである。** 同居構成では次が成立しない。

- 1 つの Deployment が両データベースを含む
- 切替はエンドポイント単位のため、**ステージと本番が同時に切り替わる**
- パラメータグループもインスタンス単位のため、環境ごとに別の値を設定できない

つまり「ステージで検証してから本番」という段階そのものが成立しない。

### 本リポジトリのスクリプトは同居構成で誤動作する

`build_green.sh` と `switchover.sh` は、`source_db_instance_identifier` から ARN を引き、`describe-blue-green-deployments --filters Name=source,Values=<arn>` で Deployment を解決する。同居構成では `staging.yml` と `production.yml` が**同じインスタンス識別子**を持つため、次が起こる。

| 操作 | 実際に起こること |
|---|---|
| staging の `build: approved` | Deployment を作成する |
| production の `build: approved` | 「既に存在する」と判定して `exit 0`。**成功したように見えるが何もしていない** |
| **staging の `switchover: approved`** | **本番も同時に切り替わる** |
| どちらかの `cleanup: approved` | 共有していた旧インスタンスを削除する |

**承認ゲートが意味をなさない。** 「ステージの切替を承認したつもりが本番を切り替えた」という事故が起こりうる。

したがって同居構成では、**設定ファイルを環境別に分けるモデル自体が使えない。** 後述のとおり物理インスタンス単位に 1 本化する。

## 方針

使い捨ての検証機で先行検証し、本番の共有インスタンスは検証通過後に 1 回だけ上げる。

```
共有インスタンス（8.0）
  │
  ├─[スナップショット]→ 検証機を復元 →[インプレースで 8.4 へ]→ 検証 → 破棄
  │                                                              ↓ 通過
  └──────────────── Blue/Green で 8.4 へ（本番はここで無停止切替）
```

コストが発生するのは検証期間だけであり、恒久的なインスタンス追加を必要としない。Step 1 が「MyISAM 棚卸しと MySQL Shell の互換性チェックはスナップショット復元機に対して実施する」としているのと同じ考え方の延長である。

### なぜリードレプリカではなくスナップショット復元か

書き込みを伴う検証が目的であるため、最初から独立して書き込める復元機が適している。

| | リードレプリカ | **スナップショット復元** |
|---|---|---|
| 書き込み | `read_only` で不可。昇格が必要 | **最初から書き込み可能** |
| 本番への影響 | レプリケーション負荷が継続する | **復元後は完全に独立** |
| インスタンスクラス | ソースに準じる | **小さくしてコストを下げられる** |

### なぜ検証機に Blue/Green を使わないのか

Blue/Green は**無停止切替のための仕組み**である。使い捨ての検証機では停止を許容できるため不要であり、`modify-db-instance` によるインプレースのメジャーバージョンアップグレードで足りる。インスタンスが 1 台で済み、手順も短くなる。

## 構築手順

### 1. パラメータグループを複製する

**本番の 8.0 パラメータグループをそのまま検証機に付けてはならない。** 検証中に値を変えると本番へ波及する。

```sh
aws rds copy-db-parameter-group \
  --source-db-parameter-group-identifier <本番の 8.0 グループ名> \
  --target-db-parameter-group-identifier verify-mysql80-copy \
  --target-db-parameter-group-description "temporary: 8.4 upgrade verification"
```

### 2. スナップショットを取得する

```sh
snapshot_id="verify-src-$(date -u +%Y%m%d)"

aws rds create-db-snapshot \
  --db-instance-identifier <共有インスタンス> \
  --db-snapshot-identifier "$snapshot_id"
aws rds wait db-snapshot-available --db-snapshot-identifier "$snapshot_id"
```

> Single-AZ の場合、スナップショット取得中に短時間の I/O 停止が発生する。本番影響を避けるなら、代わりに **PITR（`restore-db-instance-to-point-in-time`）** を使う。既存の自動バックアップから復元するため、本番に一切触れない。

ステージを停止できるなら、**先にステージアプリを停止してから取得する**と、検証中のドリフトを考えなくて済む。

### 3. 検証機を復元する

```sh
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier verify-mysql84 \
  --db-snapshot-identifier "$snapshot_id" \
  --db-instance-class db.t4g.medium \
  --db-parameter-group-name verify-mysql80-copy \
  --no-multi-az \
  --no-publicly-accessible \
  --no-auto-minor-version-upgrade \
  --db-subnet-group-name <subnet-group> \
  --vpc-security-group-ids <sg-id> \
  --tags Key=Purpose,Value=mysql84-verification Key=Disposable,Value=true

aws rds wait db-instance-available --db-instance-identifier verify-mysql84
```

- 検証用途のためインスタンスクラスは小さくできる
- `--db-parameter-group-name` を省略すると**デフォルトグループが付く**ため必ず指定する
- マスターユーザーのパスワードはスナップショット元と同じである。分離したい場合は `modify-db-instance --master-user-password` で変更する

### 4. 8.4 へインプレースアップグレードする

Step 2 で生成した**本番用の 8.4 パラメータグループをそのまま指定する。** 検証対象はこの成果物そのものである。

```sh
aws rds modify-db-instance \
  --db-instance-identifier verify-mysql84 \
  --engine-version 8.4.10 \
  --allow-major-version-upgrade \
  --db-parameter-group-name <Step 2 で作成した 8.4 グループ> \
  --apply-immediately

aws rds wait db-instance-available --db-instance-identifier verify-mysql84
```

**アップグレードが失敗したら、それ自体が検証結果である。** RDS は事前チェックを行い、失敗するとイベントに理由が出る。

```sh
aws rds describe-events --source-identifier verify-mysql84 \
  --source-type db-instance --duration 120
```

パラメータグループの修正が必要になった場合、**その場で直さず Step 2 の CloudFormation 経路で修正して再検証する。** 変更経路を CloudFormation に閉じるという方針を検証時にも守る。

### 5. 検証する

ステージアプリを検証機のエンドポイントへ向け、**書き込みを伴う検証**を行う。

- アプリケーションのテストスイート、日次バッチの完走
- `DEFAULT CURRENT_TIMESTAMP` の挙動、タイムゾーン関連（[mysql-timezone-problem-summary.md](mysql-timezone-problem-summary.md)）
- 重いクエリの実行計画比較

### 6. 後始末

```sh
aws rds delete-db-instance --db-instance-identifier verify-mysql84 \
  --skip-final-snapshot --delete-automated-backups
aws rds wait db-instance-deleted --db-instance-identifier verify-mysql84

aws rds delete-db-parameter-group --db-parameter-group-name verify-mysql80-copy
aws rds delete-db-snapshot --db-snapshot-identifier "$snapshot_id"
```

## Green の併用

検証機とは別に、**Blue/Green の Green を読み取り検証に使う。** 両者は検証している対象が異なり、相補的である。

| | 検証機（スナップショット復元） | Green |
|---|---|---|
| データ | スナップショット時点の**静止コピー** | Blue から**継続レプリケーション中の実データ** |
| 独立性 | 完全に独立。壊しても影響がない | Blue と 1 本のレプリケーションで繋がっている |
| 切替後 | 破棄する | **これが本番になる** |
| 向く検証 | **書き込みを伴う機能検証**、テストスイート、バッチ完走 | **実データの整合性**、構成・パラメータ、レプリカ遅延、読み取り経路 |

### Green へ書き込んではならない

AWS のベストプラクティスに明記がある。

> Keep your databases in the green environment read only. Enable write operations on the green environment with caution because they can result in **replication conflicts** and **unintended data in the production databases after switchover**.

技術的には `read_only` を 0 にすれば書き込めるが、次の実害がある。

1. **テストデータが本番に残る** — Green は切替後に本番そのものになる
2. **レプリケーション競合で Blue/Green 全体が壊れる** — Green に書いた行と Blue から流れてくる行が衝突すると、レプリケーションが停止する

**同居構成では 2 の危険がより大きい。** レプリケーションストリームは 1 本で両データベースを運んでいるため、**ステージ側への書き込みでレプリケーションが壊れると、本番側の同期も同時に止まる。** Blue/Green ごと作り直しになり、20〜40 分の再構築が発生する。

「ステージのデータは捨てられるから書き込んでもよい」という判断は、同居構成では成り立たない。書き込み先がステージであっても、壊れる対象は共有のレプリケーションである。

## 注意点

- **検証機は本番データを保持する。** 共有インスタンスのスナップショットには本番データベースも含まれるため、**本番と同等のアクセス制御が必要**である。緩いサブネット・セキュリティグループに置かない
- ステージ検証だけが目的なら、復元後に本番データベースを `DROP DATABASE` して露出を減らす選択肢もある。ただし本番側の互換性確認ができなくなるため、トレードオフである
- 設定ファイルは環境別ではなく**物理インスタンス単位に 1 本化する。** 切替の承認は、ステージ・本番双方のオーナーが合意した証跡として扱う

## 将来の検討事項

そもそもステージが本番インスタンスに同居していること自体が、次のリスクを抱えている。

- ノイジーネイバー（ステージの重いクエリが本番に影響する）
- 障害影響範囲の共有
- パラメータグループ・メンテナンスウィンドウの共通化
- 認証情報・権限分離の困難さ
- **変更を段階的に適用できない**（本書の主題）

移行はこれを是正する自然なタイミングだが、**移行と同時に実施すると変更が二重になる。** MySQL 8.0 の標準サポート終了という期限がある以上、インスタンス分離は移行後の別作業として扱うほうが安全である。

## 関連ドキュメント

- [upgrade-flow-steps.md](../upgrade-flow-steps.md) — Step 1〜7 の分割。本書は Step 3 の前に挟む前段の検証にあたる
- [phase-1-parameter-group-cloudformation.md](../phase-1-parameter-group-cloudformation.md) — Step 2 のパラメータグループ生成・適用
- [mysql-timezone-problem-summary.md](mysql-timezone-problem-summary.md) — 検証時に確認すべきタイムゾーン関連の論点
- [Amazon RDS ユーザーガイド — Best practices for blue/green deployments](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-best-practices.html)
