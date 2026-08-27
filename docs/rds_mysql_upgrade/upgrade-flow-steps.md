# MySQL 8.0 → 8.4 アップグレードのステップ分割メモ

> 目的: 移行手順書の Phase 0〜5 を、スクリプト／CI ジョブとして実行できる 6 つの単位に割り直す。
> 各ステップは独立して再実行でき、前ステップの成果物（JSON／YAML／識別子）だけを入力に取る。

各ステップの共通方針は次のとおり。

- 収集は AWS CLI の読み取り API（`Describe*`／`Get*`）のみ、判定はローカルの Ruby で行い、AWS を呼ぶ処理と判断する処理を分ける。
- 変更操作（スナップショット作成、Blue/Green 作成、切替）は独立したステップに閉じ込め、切替だけは明示承認フラグを必須にする。
- 判定系スクリプトは不適合時に終了コード `1` を返し、CI のジョブ失敗としてそのまま扱えるようにする。

---

## Step 1. 既存インスタンスのチェック

移行元 Blue（MySQL 8.0）が Blue/Green Deployments を作成できる状態かを、変更を一切行わずに検査する。
自動バックアップ、オプショングループ、パラメータ適用状態、インスタンスクラスの世代、レプリカ構成、空きストレージなどを収集し、`STOP`／`REVIEW` で判定する。
`STOP` が 1 件でも残る間は後続ステップへ進まない。CI では PR 単位ではなく、対象環境ごとの手動トリガージョブとして回す。

- 実装: [`scripts/collect_blue_green_prereqs.sh`](scripts/collect_blue_green_prereqs.sh) → [`scripts/evaluate_blue_green_prereqs.rb`](scripts/evaluate_blue_green_prereqs.rb)
- 詳細: [phase-0-precheck.md](phase-0-precheck.md)
- 補足: 外部 binlog レプリカの確認（0-1-06）だけは AWS API では判定できないため、DB へ接続して `SHOW REPLICA STATUS\G` の結果を証跡に残す。MyISAM 棚卸しと MySQL Shell の互換性チェックも、このステップと並行してスナップショット復元機に対して実施する。

## Step 2. 移行先パラメータグループの整理と作成

現行 8.0 パラメータグループの `Source=user` 値を採取し、8.0／8.4 の engine default と移行ルールを突き合わせて、8.4 へ持ち込む値だけを決定する。
判定結果はレビュー用の Markdown レポートと、`AWS::RDS::DBParameterGroup` のみを含む CloudFormation テンプレートとして出力する。
生成物を PR レビュー → Change Set レビューの二段で承認し、CloudFormation を唯一の変更経路としてパラメータグループを作成する。

- 実装: [`scripts/collect_mysql84_parameter_inputs.sh`](scripts/collect_mysql84_parameter_inputs.sh) → [`scripts/generate_mysql84_parameter_group.rb`](scripts/generate_mysql84_parameter_group.rb)
- ルール: [config/mysql80-to-84-parameter-rules.yml](config/mysql80-to-84-parameter-rules.yml) ／ 詳細: [phase-1-parameter-group-cloudformation.md](phase-1-parameter-group-cloudformation.md)
- 補足: 「要レビュー」「生成不可」が残ると Ruby スクリプトは終了コード `1` を返すため、ルール追加か個別判断の記録なしには CI を通せない。`innodb_buffer_pool_size` などインスタンス依存で 8.4 が自動算出する値は、原則テンプレートに固定しない。

## Step 3. スナップショット取得と Blue/Green 構成の作成

切り戻しの最終手段となる保護スナップショットを取得したうえで、Step 2 で作成済みのパラメータグループ名を指定して Blue/Green Deployment を作成する。
作成前に移行元が MySQL 8.0 であること、指定パラメータグループが `mysql8.4` ファミリーであることを読み取り API で検証してから変更操作に入る。
作成後は Deployment が `AVAILABLE` になるまで待機して終了し、切替は行わない。

- 実装: [`scripts/build_green.sh`](scripts/build_green.sh) → [`scripts/create_blue_green_deployment.sh`](scripts/create_blue_green_deployment.sh)
- 設定: [config/blue-green/production.yml](config/blue-green/production.yml) ／ [config/blue-green/staging.yml](config/blue-green/staging.yml)
- 補足: 現行スクリプトは `--target-engine-version 8.4.x` を作成時に一括指定するワンショット方式。作成に失敗すると Deployment ごと作り直しになるため、同一 8.0 で作成 → Green のみ手動昇格する二段方式を選ぶ場合はスクリプトを分割する。

## Step 4. Blue/Green 構成の設定チェックとレプリカ同期チェック

作成された Green の実構成を、宣言した内容と突き合わせて検証する。エンジンバージョン、適用パラメータグループとその `In Sync` 状態、インスタンスクラス、`Source=user` パラメータの反映を確認する。
あわせて Blue → Green のレプリケーション状態を確認し、`ReplicaLag` がほぼゼロで IO／SQL スレッドが動作していることを切替の前提条件とする。
ここが切替可否を決める最後のゲートであり、不一致・遅延がある間は Step 5 を起動できないようにする。

- 実装: [`scripts/verify_green.sh`](scripts/verify_green.sh)
- 参照: [rds-mysql-84-migration-guide.md](rds-mysql-84-migration-guide.md) の「3-1. Phase 3: Green の検証」「3-3. Phase 4: スイッチオーバー直前」
- 補足: AWS 側の構成確認（`describe-db-instances`／`describe-db-parameters`）は CI で自動化できるが、重いクエリの実行計画比較とアプリのドライバ接続試験は人手の検証として残す。切り戻し経路（binlog 保持 24 時間以上、逆レプリの準備）もこのステップで確認する。

## Step 5. Blue/Green 切り替え

検証済みの Deployment に対して `switchover-blue-green-deployment` を実行し、エンドポイントを Green へ付け替える。
本番トラフィックに影響する唯一の変更操作であるため、設定ファイルで `switchover: approved` が宣言されていることを必須とし、直前に `AVAILABLE` 状態であることを再確認してから実行する。
CI では自動実行せず、承認ステップ付きの手動ジョブとし、実行時刻・タイムアウト値・応答 JSON を証跡として保存する。

- 実装: [`scripts/switchover.sh`](scripts/switchover.sh) → [`scripts/switchover_blue_green_deployment.sh`](scripts/switchover_blue_green_deployment.sh)
- 補足: `--switchover-timeout`（既定 300 秒、最大 60 分）の間、既存コネクションは切断される。ALB／nginx のアイドルタイムアウトより短く収まるかを事前に確認しておく。

## Step 6. Green のヘルスチェック

切替直後に、新本番となった Green が書き込み可能で、エンドポイント名が変わっていないこと、各アプリが接続できていることを確認する。
その後、エラーログ・スロークエリログ・CloudWatch メトリクスを切替前と比較し、プラン悪化やメモリ／IO の異常がないかを短期・中期で追跡する。
このステップは変更操作を含まない読み取りのみのステップであり、次の後始末へ進んでよいかの判断材料を出すことが目的である。

- 実装: 未実装（`healthcheck_green.sh` 等として新規作成が必要）
- 参照: [rds-mysql-84-migration-guide.md](rds-mysql-84-migration-guide.md) の「3-4. Phase 5: 切替後のヘルスチェック」
- 補足: 即時チェック（`SELECT VERSION()`／`@@read_only`／接続確認）はスクリプト化でき、切替直後に自動実行する。短期・中期の観測はダッシュボードとアラート側で担保する。

## Step 7. 後始末

Green で問題がないと判断できた時点で、Blue/Green Deployment を削除し、旧 Blue（`-old1`）を最終スナップショット付きで削除して二重課金を止める。
プリチェック用に復元した検証インスタンスや踏み台、逆レプリケーションを張っていた場合はその停止もここでまとめて行う。
旧環境を不可逆に失う操作を含むため、Step 6 の観測期間を経たうえで明示承認を必須とし、切替直後には実行できないようにする。

- 実装: 未実装（`cleanup.sh` 等として新規作成が必要）
- 参照: [rds-mysql-84-migration-guide.md](rds-mysql-84-migration-guide.md) の「後始末」
- 補足: このステップを実行すると切り戻し経路が消える。Step 6 の中期観測（週次・月次バッチの完走）まで待ってから実行する運用とし、Extended Support 課金が発生していないことを翌月の請求で確認するまでを完了条件に含める。

---

## 実装状況まとめ

| Step | 内容 | 変更操作 | 実装 | ワンストップ実行 | 実行形態 |
|---|---|---|---|---|---|
| 1 | 既存インスタンスのチェック | なし | あり | 不可（収集と判定で 2 コマンド） | ローカル |
| 2 | パラメータ整理とパラメータグループ作成 | CloudFormation のみ | あり | 不可（収集・生成・CFn 適用が分断） | ローカル |
| 3 | スナップショット取得と Blue/Green 作成 | あり | あり | 可 | CI |
| 4 | Green 設定チェック＋レプリカ同期チェック | なし | あり | 可 | CI |
| 5 | Blue/Green 切り替え | あり（本番影響） | あり | 可 | CI（承認付き） |
| 6 | Green ヘルスチェック | なし | なし | — | ローカル（DB 接続）＋ CI（AWS API 部分） |
| 7 | 後始末 | あり（旧 Blue 削除） | なし | — | CI（承認付き） |

---

# 実行形態の整理

## ローカル実行と CI 実行の切り分け

実行形態は「AWS リソースを変更するか」と「DB への直接接続を必要とするか」の 2 軸で決める。

**Step 1〜2 はローカル実行（人が回す調査・生成フェーズ）**

- 出力が「判定結果」と「レビュー対象の生成物」であり、実行そのものではなく人のレビューが目的である。
- 何度も再実行して不適合を潰していく反復作業であり、実行ごとに CI の履歴を残す価値が薄い。
- Step 2 が生成した CloudFormation テンプレートはリポジトリへコミットし、PR レビューを経てからローカルで適用する。適用対象がパラメータグループ 1 リソースに閉じており、DB インスタンスへ関連付ける前であるため、この時点では本番影響がない。
- 変更経路が CloudFormation に閉じているため、適用そのものは Change Set のレビューで統制できる。誤りがあってもスタックの更新・削除でやり直せる。CI 化して実行環境を固定する価値より、テンプレート修正と再適用を手元で素早く回せる利点が上回る。

**Step 3〜5 と Step 7 は CI 実行（環境を変更する作業フェーズ）**

- AWS リソースを変更する、あるいは切替可否を決めるため、誰がいつ実行したかの記録と、承認の強制が必要になる。
- 手元の AWS プロファイル差異や CLI バージョン差異による事故を避け、実行環境を固定したい。
- Step 3（構築）と Step 5（切替）は実行日が数日〜数週間離れるため、その間の状態をどこかで保持する必要がある。
- いずれも AWS API だけで完結し、DB への直接接続を必要としない。

**Step 6 はローカルと CI に分割する**

Green のヘルスチェックは DB へ接続して `SELECT VERSION()`、`@@read_only`、書き込み疎通を確認する部分を含む。本リポジトリの DB アクセスは、ローカルのコンテナに認証情報を読み取り専用でマウントし、パスワードを対話入力して `VERIFY_CA` で接続する方式である（[docker/README.md](docker/README.md)）。これを CI に載せるには、ランナーを DB へ到達可能なネットワークに置き、本番 DB の認証情報を CI シークレットとして常設する必要がある。読み取り専用の確認のために本番 DB 認証情報を CI へ持ち込む判断は避け、次のように分割する。

| Step 6 の内容 | 実行形態 | 理由 |
|---|---|---|
| エンドポイント名・インスタンス状態の確認、CloudWatch メトリクスの切替前後比較 | CI（`switchover` 成功後に自動） | AWS API のみで完結し、切替直後の証跡として自動で残したい |
| `SELECT VERSION()`／`@@read_only`／代表的な書き込み処理の疎通 | ローカル | DB 接続と対話パスワードが必要。切替直後は担当者が立ち会っており、手元実行が自然 |
| アプリの主要画面・バッチの確認、短期〜中期のログ・メトリクス観測 | ローカル／ダッシュボード | スクリプト化の対象外。アラートと監視基盤で担保する |

**Step 7 は CI 実行（承認付き）**

- 旧 Blue の削除は不可逆であり、実行者・実行時刻の記録と承認ゲートが必須である。
- AWS API のみで完結し、DB 接続を必要としないため CI に載せる障壁がない。
- 削除対象は設定ファイルの `source_db_instance_identifier` を起点に、切替後の旧 Blue（`-old1`）を AWS から引き当てて解決するため、引数の取り違えが起きにくい。
- `rds:DeleteDBInstance` 等の破壊的権限は CI 実行ロールにのみ付与し、通常の作業者の手元からは実行できない状態にする。

## ワンストップ実行のための整理

現状はどのステップも複数コマンドの手順として書かれており、1 コマンドで完結しない。CI ジョブ化にあたり、各ステップに単一のエントリポイントを用意する。

| ステップ | 実行形態 | エントリポイント | 内部で実行する処理 |
|---|---|---|---|
| Step 1 | ローカル | `scripts/precheck.sh --config FILE --service NAME` | 収集 → 判定 → レポート出力 |
| Step 2 | ローカル | `scripts/generate_parameter_group.sh --config FILE --service NAME` | 収集 → ルール突合 → レポートと CFn テンプレート生成 |
| Step 2 適用 | ローカル | `scripts/deploy_parameter_group.sh --config FILE --service NAME` | Change Set 作成 → レビュー → 実行 → 作成結果の読み取り検証 |
| Step 3 | CI | `scripts/build_green.sh --config FILE --service NAME` | 保護スナップショット取得 → Blue/Green 作成 → `AVAILABLE` 待機 |
| Step 4 | CI | `scripts/verify_green.sh --config FILE --service NAME` | Green 構成の突合 → レプリカ同期確認 → 判定 |
| Step 5 | CI | `scripts/switchover.sh --config FILE --service NAME` | 宣言と状態の突き合わせ → 切替 → 完了待機 |
| Step 6 | CI | `scripts/healthcheck_green_aws.sh --config FILE --service NAME` | エンドポイント・インスタンス状態の確認 → メトリクス比較 |
| Step 6 | ローカル | `scripts/healthcheck_green_db.sh --config FILE --service NAME` | DB 接続 → バージョン・`read_only`・書き込み疎通の確認 |
| Step 7 | CI | `scripts/cleanup.sh --config FILE --service NAME` | 宣言と状態の突き合わせ → Deployment 削除 → 旧 Blue の最終スナップショット付き削除 |

Step 2 は生成と適用でエントリポイントを分けるが、どちらもローカル実行である。生成を反復してテンプレートを固め、PR レビューを経てから Change Set で適用する。Step 6 は DB 接続の有無でエントリポイントを 2 つに分ける。AWS API のみの確認は CI から DB 認証情報なしで実行でき、DB 接続を伴う確認はローカルのコンテナから対話パスワードで実行する。

いずれも `--config` と `--service` だけを引数に取り、DB 識別子・バージョン・パラメータグループ名は設定ファイルから解決する。これにより CI ジョブ側は「どの設定ファイルの、どのサービスに対して、どのステップを実行するか」だけを指定すればよくなる。

## 設定ファイルによる 3 アクションの管理

AWS リソースを変更する CI ジョブは Step 3（移行構築）、Step 5（移行切り替え）、Step 7（後始末）の 3 つであり、それぞれ実行タイミングが数日〜数週間離れる。間には読み取りのみの Step 4（構築の検証）と Step 6（切替後の検証）が入り、その結果が次のアクションを実行してよいかの判断材料になる。

設定ファイルが持つのは**進捗の記録ではなく、利用者が「このアクションを実行してよい」と宣言した意図**である。CI は設定ファイルの宣言と、AWS から取得した実際の環境状態を突き合わせ、適用できるなら適用し、すでに適用済みなら何もしない。CI が設定ファイルへ書き戻すことはしない。

- 設定ファイル = 意図（desired）。人間が PR で変更する。
- AWS の実環境 = 事実（actual）。CI が読み取り API で毎回取得する。
- CI ジョブ = 両者を比較し、差分があり前提を満たす場合にだけ適用する。

進捗を設定ファイルへ書き戻さないため、CI から人間へ向けた PR が不要になり、リポジトリの状態と実環境がずれる余地もなくなる。「構築済みか」「切替済みか」は常に AWS へ問い合わせて判定する。

```yaml
# config/blue-green/production.yml
environment: production
aws_region: ap-northeast-1

services:
  example-service:
    source_db_instance_identifier: example-service-production-mysql80
    target_engine_version: 8.4.10
    target_db_instance_class: db.r6g.large
    target_db_parameter_group_name: example-service-production-mysql84-v1
    protection_snapshot_identifier: example-service-production-mysql80-pre-bg-20260828

    actions:
      # Step 3: 保護スナップショット取得と Blue/Green 構成の作成。
      build: approved

      # Step 5: 本番の Green への切り替え。
      # Step 4 の検証が通ったことを根拠に、PR で approved へ変更する。
      switchover: pending
      switchover_timeout: 300

      # Step 7: 旧 Blue の削除。
      # Step 6 の観測期間を経たことを根拠に、PR で approved へ変更する。
      cleanup: pending
```

各アクションは次の 2 値をとる。

| 値 | 意味 | CI の振る舞い |
|---|---|---|
| `pending` | 未承認。実行してよいとまだ判断していない | 何もせず正常終了する |
| `approved` | 承認済み。実行してよいと人間が判断した | 実環境と突き合わせ、未適用なら適用する |

| アクション | 対応ステップ | `approved` が意味すること | 承認に必要な根拠 |
|---|---|---|---|
| `build` | Step 3 | スナップショットを取り、Green を作ってよい | Step 1／2 の完了 |
| `switchover` | Step 5 | 本番トラフィックを Green へ向けてよい | Step 4 の検証結果 |
| `cleanup` | Step 7 | 旧 Blue を削除し、切り戻し経路を破棄してよい | Step 6 の観測結果 |

Step 4 と Step 6 は読み取りのみで環境を変更しないため、対応するアクションを持たない。設定ファイルの変更なしにいつでも実行できる。

### 宣言と実環境の突き合わせ

各ジョブは実行のたびに、AWS から実際の状態を取得して適用要否を判定する。

| ジョブ | 実環境の判定方法 | 適用する条件 |
|---|---|---|
| Step 3 構築 | `describe-blue-green-deployments` に対象 Blue を source とする Deployment が存在するか、`describe-db-snapshots` に保護スナップショットが存在するか | `build: approved` かつ Deployment が未作成 |
| Step 5 切替 | 対象 Deployment の `Status` が `AVAILABLE` か `SWITCHOVER_COMPLETED` か | `switchover: approved` かつ `Status == AVAILABLE` |
| Step 7 後始末 | Deployment の存在、旧 Blue（`-old1`）インスタンスの存在 | `cleanup: approved` かつ `Status == SWITCHOVER_COMPLETED` かつ旧 Blue が残存 |

判定結果に応じたジョブの振る舞いは次の 4 通りである。

| 宣言と実環境の関係 | 振る舞い | 終了コード |
|---|---|---|
| `pending` | 何もしない | `0` |
| `approved` かつ未適用・前提充足 | 適用する | `0` |
| `approved` かつ適用済み | 何もしない（冪等） | `0` |
| `approved` だが前提未充足 | 適用せず理由を出力して失敗する | `1` |

- 「前提未充足」とは、たとえば `switchover: approved` だが Deployment がまだ `AVAILABLE` でない、`cleanup: approved` だが切替が完了していない、といった状態を指す。設定の誤りか実環境の異常であり、黙って成功させない。
- `approved` から `pending` へ戻しても、適用済みのものを取り消す動作は**行わない**。`pending` は「実行を承認していない」であり「元に戻す」ではない。切り戻しは逆レプリケーションや復元として別に扱う。
- 適用済みの判定を AWS 側の事実に置くため、ジョブの再実行、途中失敗後のリトライ、複数人による同時トリガーのいずれでも二重作成・二重切替は起こらない。

### CI ジョブの構成

| ジョブ | トリガー | 承認 |
|---|---|---|
| `build-green` | 手動トリガー（環境・サービスを指定） | 不要（本番影響なし） |
| `verify-green` | `build-green` 成功後に自動、以降は定期実行 | 不要 |
| `switchover` | 手動トリガー | 必須（`switchover: approved` の PR ＋ ジョブ承認） |
| `healthcheck-green-aws` | `switchover` 成功後に自動、以降は観測期間中に定期実行 | 不要 |
| `cleanup` | 手動トリガー | 必須（`cleanup: approved` の PR ＋ ジョブ承認） |

Step 1、Step 2（生成・適用とも）、Step 6 の DB 接続部分は CI ジョブにせず、作業手順としてローカルから実行し、結果を作業チケットへ証跡として残す。

`verify-green` を定期実行に載せておくと、構築から切替までの待機期間中にレプリカ遅延や構成のドリフトが発生した場合に検知できる。

### CI 実行ロールに必要な権限

Blue/Green の作成・切替・削除に関わる変更権限は CI 実行ロールにのみ付与し、通常の作業者の手元からは実行できない状態にする。

| ジョブ | 主な変更権限 |
|---|---|
| `build-green` | `rds:CreateDBSnapshot`、`rds:CreateBlueGreenDeployment` |
| `verify-green` / `healthcheck-green-aws` | なし（`Describe*`／`Get*` のみ） |
| `switchover` | `rds:SwitchoverBlueGreenDeployment` |
| `cleanup` | `rds:DeleteBlueGreenDeployment`、`rds:ModifyDBInstance`、`rds:DeleteDBInstance` |

ローカル実行のうち、Step 1 と Step 6 は読み取り権限のみで足りる。Step 2 の適用だけは例外で、`rds:CreateDBParameterGroup`／`rds:ModifyDBParameterGroup` を CloudFormation 実行ロール経由で行使する。作業者には CloudFormation スタックを操作する権限だけを与え、RDS API を直接叩く権限は与えない。
