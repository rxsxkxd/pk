# 構成・フロー見直しの対案

> 位置づけ: **未採択の検討メモ**である。現行の構成（[upgrade-flow-steps.md](upgrade-flow-steps.md)）を否定するものではなく、Step 6／7 の実装と対象 DB の追加を進める前に決着させておきたい論点と、その対案をまとめる。
> 対象: リポジトリ全体の構成とフローの形。個々のスクリプトの不具合ではない。

## 0. 現行方針のうち維持すべき点

以下は先に確定させておく。対案はこれらを前提として組み立てる。

- **宣言（設定ファイル）と事実（AWS）を突き合わせる reconciliation 型。** 進捗を設定ファイルへ書き戻さないため、CI から人へ向けた PR が不要で、リポジトリと実環境がずれない。
- **識別子を設定ファイルに持たず AWS から引き当てる。** `describe-blue-green-deployments --filters Name=source,Values=<arn>` で毎回解決するため、再実行・リトライ・同時トリガーで二重作成・二重切替が構造的に起こらない。冪等性を運用の注意ではなく設計で担保している。
- **収集（AWS 読み取り API）と判定（AWS を呼ばない）の分離。** 収集済み JSON に対するオフライン再判定、レビュー、障害調査が成立する。
- **本番 DB 認証情報を CI に常設しない。** Step 6 をローカルと CI に割る判断はこの線引きから導かれており、逆順ではない。
- **判定系は不適合時に終了コード `1` を返す。**
- **RDS DB パラメータグループの変更経路を CloudFormation に閉じる。** Blue/Green Deployment 自体は AWS CLI で扱う。

## 1. 論点の一覧

効きの大きい順に並べる。No.1〜4 が構造に関わるもの、No.5 以降は整理である。

| # | 論点 | 現状 | 影響 |
|---|---|---|---|
| 1 | 実装言語が 4 つある | bash + インライン python + Ruby + Go | 重複実装の維持コスト、テスト不能 |
| 2 | 切替判定に自動テストがない | ゴールデンファイルが Step 2 のみ | 本番切替の可否を決めるロジックが未検証 |
| 3 | 切り戻しが Step になっていない | 手順書のチェックリストのみ | 最大リスク時間帯が手作業 |
| 4 | ワンショット昇格か二段階昇格か未決 | 実装と手順書が不一致 | Step 3 の分割単位が決まらない |
| 5 | 設定ファイルが仕様と承認を混在 | `actions` と識別子が同階層 | レビュー観点が混ざる、日付の手更新 |
| 6 | CI が二重実装 | GitHub Actions と CodePipeline | 呼び出し規約変更のたびに両方修正 |
| 7 | 承認ゲートを迂回する公開経路 | 内側スクリプトを README が案内 | `actions` の宣言を見ずに変更操作が可能 |
| 8 | 番号体系が 3 つある | Phase／Step／0-1-NN | 正典が不明確 |

---

## 2. 論点 1 — 実装言語を 1 つに寄せる

### 現状

| 種別 | 箇所 |
|---|---|
| インライン `python3 -c` | 8 ファイル・計 38 箇所（`verify_green.sh` だけで 12） |
| Ruby | `evaluate_blue_green_prereqs.rb` 106 行、`generate_mysql84_parameter_group.rb` 307 行、`generate_green_verification_report.rb` 114 行 |
| Go | `generate_green_verification_report.go` 259 行（Ruby 版と同一機能） |
| bash | 9 ファイル。各々が同じ `--config/--service/--region/--profile/--output-dir` のパースを持つ |

とくに次の 2 点が構造的な負債である。

- インライン python が 1 行に `(_ for _ in ()).throw(SystemExit(...))` を詰め込む形式であり、読めない・単体テストできない・エラーメッセージを制御できない。設定ファイル解析という同じ処理が各スクリプトに散っている。
- レポート生成器の Ruby 版と Go 版が並存している。Go 版は CodeBuild に Ruby ランタイムを置かないためだけに存在し、そのために `VerifyGreenProject` を `PrivilegedMode: true` にして Docker マルチステージビルドを回している。**ランタイムを 1 つ導入しない代償として、実装の重複とビルド特権を購入している**状態であり、収支が合っていない。

### 対案

判定・レポート生成・設定ファイル解決を 1 言語へ寄せ、bash は AWS CLI を呼ぶ薄い層に留めるか廃する。

| 案 | 内容 | 得られるもの | 代償 |
|---|---|---|---|
| **A. Go 単一バイナリ（推奨）** | `rdsbg build｜verify｜switchover｜cleanup --config FILE --service NAME` を 1 バイナリに集約。AWS SDK for Go を使い AWS CLI 依存も外す | CI にランタイム不要（`PrivilegedMode` も `PyYAML` 導入も不要）、設定解析が 1 箇所、判定ロジックが単体テスト可能、配布が 1 ファイル | Ruby 資産 527 行の移植 |
| **B. Ruby へ集約** | Go 版を削除し、インライン python を `scripts/lib/config.rb` へ集約 | 移植量が最小 | CI に Ruby ランタイムが必要（コンテナ 1 つで済む） |

いずれを選ぶかより、**二重実装を維持しないこと**が要点である。判断が遅れるほど移植量が増える。

案 A を採る場合の移行順序を以下に示す。

1. 設定ファイル解決とアクション判定を Go に実装し、`--config`／`--service` から解決した値を JSON で出力するサブコマンドを作る。既存 bash はまずこれを呼ぶだけに変える（インライン python の除去）。
2. `generate_green_verification_report.rb` を削除し、Go 版に一本化する。`GREEN_REPORT_GENERATOR` の分岐と `PrivilegedMode: true` を外す。
3. `evaluate_blue_green_prereqs.rb`／`generate_mysql84_parameter_group.rb` を移植する。この 2 つはローカル実行のみで CI に載らないため、優先度は低い。

---

## 3. 論点 2 — 判定ロジックに自動テストを入れる

### 現状

`actions` の宣言と AWS の実状態から「適用する／何もしない／失敗する」を決める判定は、本リポジトリで最も影響の大きいロジックである。現在の回帰確認手段は `examples/mysql84-parameter-generation/` のゴールデンファイルのみで、これは Step 2 のパラメータグループ生成しか覆っていない。

つまり、**本番トラフィックを切り替えてよいかを決めるコードに自動検証がない**。

### 対案

判定を副作用（AWS 呼び出し、ファイル出力）から切り離した純粋関数とし、`(宣言, 実状態) → 決定` の対応表をそのままテーブル駆動テストにする。

| 宣言 | 実状態 | 期待する決定 | 終了コード |
|---|---|---|---|
| `pending` | 未適用 | 何もしない | `0` |
| `pending` | 適用済み | 何もしない（取り消さない） | `0` |
| `approved` | 未適用・前提充足 | 適用する | `0` |
| `approved` | 適用済み | 何もしない | `0` |
| `approved` | 前提未充足 | 理由を出力して失敗する | `1` |

「前提」はアクションごとに異なる（Step 5 は `Status == AVAILABLE`、Step 7 は `SWITCHOVER_COMPLETED` かつ旧 Blue が残存）。これらを 1 つの表に落とし、PR で実行する。

CI 化の価値は実行環境の固定にもあるが、**この判定が壊れていないことの保証**が本来の中心である。現状はそこが空白になっている。

---

## 4. 論点 3 — 切り戻しを Step として立てる

### 現状

`cleanup` の承認条件は「旧 Blue を削除し、切り戻し経路を破棄してよい」と定義されている。破棄の可否を判断する立場でありながら、**切り戻しそのものを実行・支援する手順が Step になっていない**。逆レプリケーションは移行手順書 Phase 3 に「任意だが推奨」のチェックリストとして存在するのみで、`scripts/` にも `actions` にも対応物がない。

切替直後は最もリスクが高く、かつ落ち着いた判断が難しい時間帯である。ここだけが文書を読んで手で対応する運用になっているのは、設計の重心がずれている。

### 対案

Step 5 と Step 7 の間に **Step 6.5「切り戻し経路の確認」** を置く。実行判断は人が行うとしても、判断材料の収集はスクリプト化する。

| 収集項目 | 取得元 | 判断への寄与 |
|---|---|---|
| 旧 Blue（`-old1`）の存在と状態 | `describe-db-instances` | 逆レプリの成立可否 |
| 逆レプリケーションの状態 | 新 Blue への DB 接続 | 切り戻しの現実性 |
| binlog 保持時間 | パラメータ／`mysql.rds_show_configuration` | 切り戻し可能な時間窓 |
| 保護スナップショットの世代と作成時刻 | `describe-db-snapshots` | 最終手段の復元点 |
| 切替後の経過時間と書き込み量 | CloudWatch | 時間経過に伴う非現実性の判定 |

「いま生きている切り戻し手段は何か」を 1 コマンドで出せることに価値がある。これはそのまま `cleanup: approved` のレビュー材料になり、Step 7 の承認根拠を「Step 6 の観測結果」から一段具体化できる。

なお、この Step 自体は読み取りのみであり、Step 4／6 と同様に `actions` を持たない。

---

## 5. 論点 4 — ワンショット昇格か二段階昇格か

### 現状

| 参照 | 方式 |
|---|---|
| `scripts/create_blue_green_deployment.sh` | 作成時に `--target-engine-version 8.4.x` を指定する**ワンショット** |
| `rds-mysql-84-migration-guide.md` Phase 2 | Blue と同じ 8.0.x で作成し、Green のみ手動昇格する**二段階** |

実装と手順書が食い違ったままである。

### 判断材料

| 観点 | ワンショット | 二段階 |
|---|---|---|
| 手数 | 1 コマンド | 作成と昇格の 2 段 |
| 失敗時のやり直し単位 | Deployment ごと作り直し | 昇格のみ再試行できる |
| 検証の粒度 | 8.4 の Green を直接検証 | 8.0 Green でレプリ成立を確認してから昇格 |
| Step 3 の分割 | 現行のまま | 「作成」と「昇格」に割れ、`actions` が増える可能性 |

### 対案

**これはフロー全体の形を決める分岐であり、Step 6／7 の実装より前に決着させる。** 二段階を採るなら Step 3 が 2 つに割れ、`actions.build` の粒度も見直しになるため、後から変えると波及が広い。

対象 DB が少数で、作り直しのコスト（20〜40 分）を許容できるならワンショットで足りる。台数が多い、または作成失敗の再試行を細かく制御したい場合は二段階を選ぶ。決定した側に合わせて、手順書と実装のどちらかを修正する。

---

## 6. 論点 5 — 設定ファイルを仕様と承認に分ける

### 現状

```yaml
source_db_instance_identifier: ...                     # 半年変わらない
target_engine_version: 8.4.10                          # 半年変わらない
protection_snapshot_identifier: ...-pre-bg-20260828    # 1 回きり・日付を手で記述
actions:
  build: pending                                       # 数日〜数週で書き換わる
```

変更頻度もレビュー観点も異なる値が同階層に並んでいる。とくに `protection_snapshot_identifier` は、宣言的な設定ファイルに実行 1 回分の値を手で書く形になっており、Step 3 をやり直すたびに日付の更新が必要になる。更新を忘れると `describe-db-snapshots` が既存を検出して取得をスキップし、古いスナップショットのまま Blue/Green を作る導線が残る。

### 対案

```yaml
services:
  example-service:
    spec:
      source_db_instance_identifier: example-service-production-mysql80
      target_engine_version: 8.4.10
      target_db_instance_class: db.r6g.large
      target_db_parameter_group_name: example-service-production-mysql84-v1
      target_parameter_group_template_path: ...
      protection_snapshot: required        # required | skip。識別子は規約から導出する
    actions:
      build: pending
      switchover: pending
      switchover_timeout: 300
      cleanup: pending
```

- `spec`（仕様）と `actions`（承認）を分けることで、PR の diff から「今回何を承認したのか」が一目で分かる。レビュアーも変える。
- 保護スナップショット名は `{source_db_instance_identifier}-pre-bg-{YYYYMMDD}` の規約から導出する。設定ファイルには識別子ではなく**意図**（取得するか否か）だけを置く。これは「識別子を設定ファイルに持たず引き当てる」という既存方針と一貫する。
- `switchover_timeout` は承認ではなく実行パラメータなので、厳密には `spec` 側が適切である。ただし切替の実行条件として一緒に見たい値でもあるため、`actions` に残す判断もありうる。

---

## 7. 論点 6 — CI を片系に寄せる

### 現状

| 系統 | 定義 |
|---|---|
| GitHub Actions | `.github/workflows/{build-green,verify-green,switchover}.yml` |
| CodeBuild / CodePipeline | `ci/codebuild/*.yml` 3 本 ＋ `examples/rds-blue-green-deployment/codepipeline.yml` |

`scripts/*.sh` を共有しているため実行内容の乖離は起きにくいが、呼び出し規約（引数、環境変数、成果物パス）を変えるたびに両方の修正が必要である。

またローカル検証手段も `nektos/act`（Actions 用）と CodeBuild Local Agent（buildspec 用）の 2 系統を維持しており、後者は専用 image `rds-codebuild-runner:local` の作成と `codebuild_build.sh` の改変まで含む。

### 対案

一方を本番、他方を参考実装として明示的に格下げする。判断軸は次のとおり。

| 条件 | 選ぶ側 |
|---|---|
| 開発フローが GitHub 中心、OIDC で AWS へ入る運用が既にある | GitHub Actions |
| AWS アカウント内で実行と証跡を完結させる統制要件がある | CodePipeline |
| 対象 DB が 5 台を超える | GitHub Actions（CodePipeline はサービス×環境ごとに 1 スタック必要で線形に増える） |

両方を等価に維持する理由が組織要件にないなら、片方を削るのが最も効く。格下げした側は `examples/` へ移し、「参考実装であり追随保証はしない」と明記する。

---

## 8. 論点 7 — 承認ゲートを迂回する公開経路を塞ぐ

### 現状

| Step | 外側（`actions` を見る） | 内側（見ない） |
|---|---|---|
| 3 | `build_green.sh` | `create_blue_green_deployment.sh` |
| 5 | `switchover.sh` | `switchover_blue_green_deployment.sh` |

`examples/rds-blue-green-deployment/README.md` は内側の 2 本を直接実行する手順を案内している。内側は設定ファイルの承認宣言を参照しないため、**承認ゲートを迂回する経路が公式に文書化されている**状態である（`switchover_blue_green_deployment.sh` は `--approve` フラグを要求するが、これは設定ファイルの `switchover: approved` とは別物である）。

### 対案

いずれかを採る。

1. 内側 2 本を `scripts/internal/` へ移し、README は外側のみを案内する。
2. 内側にも設定ファイルの承認チェックを入れる（外側と二重になるが、迂回経路がなくなる）。

論点 1 の案 A（単一バイナリ）を採る場合、内外の分離自体が消えるためこの論点も同時に解消する。

---

## 9. 論点 8 — 番号体系とドキュメント配置

### 現状

| 体系 | 使用箇所 |
|---|---|
| Phase 0〜5 | `rds-mysql-84-migration-guide.md` |
| Step 1〜7 | `upgrade-flow-steps.md` |
| 0-1-01〜14 | `phase-0-precheck.md`、`evaluate_blue_green_prereqs.rb` の出力 |
| 1〜7（＋5.5） | `1.md`（出典記事の要約メモ。独自採番） |

ルート直下に .md が 8 本フラットに並んでおり、どれが正典か外から分からない。

### 対案

**Step 1〜7 を唯一の背骨と宣言する。** Phase 系は「Step N の詳細リファレンス」として従属させ、対応表は `upgrade-flow-steps.md` に 1 つだけ置いて他所では複製しない。`0-1-NN` はスクリプト出力と対応する項目 ID なので維持する。

配置は次のように整理する。

```
docs/
  runbook/        upgrade-flow-steps.md（背骨）、phase-*.md
  reference/      innodb-mysql80-to-84-parameter-mapping.md
                  source-article-notes.md（現 1.md）
  decisions/      cdk-adoption-considerations.md
                  binlog-format-bluegreen-compatibility.md
```

`cdk-adoption-considerations.md` と `binlog-format-bluegreen-compatibility.md` は実質 ADR（結論 → 理由 → 代替案の評価）であり、既に「## 結論」から始まっている。`decisions/` に置いて決定日と採否を明示するだけで、後から読む際の負荷が下がる。本ファイルも決着後は `decisions/` へ移す。

---

## 10. 着手順

| 順 | 作業 | 理由 |
|---|---|---|
| 1 | 論点 4（ワンショット／二段階）を決める | フローの形が決まる。他の作業の前提になる |
| 2 | 論点 1（言語統一）で Go 版か Ruby 版のどちらかを捨てる | 重複の維持コストを止める |
| 3 | 論点 2（判定のテーブル駆動テスト） | 本番切替の安全弁 |
| 4 | 論点 3（切り戻しを Step 化） | 最大リスク時間帯の空白を埋める |
| 5 | 論点 5（設定ファイルの分割） | 上記に伴う設定変更とまとめて実施する |
| 6 | 論点 6・7・8（CI 片系化、迂回経路、ドキュメント整理） | 整理。急がない |

1〜4 が構造に効く部分である。**Step 6／7 の実装より先に 1 と 2 を片付けると、Step 6／7 がその形に素直に乗る。**
