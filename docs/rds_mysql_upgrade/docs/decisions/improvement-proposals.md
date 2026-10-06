# 改善提案（2026-10 時点）

> 位置づけ: **未採択の提案リスト**である。2026-10-06 時点のリポジトリを点検した結果を、重要な順に並べた。採否と着手順は別途決める。
> 各項目の「現状」はこの日に確認した事実である。対応したら該当項目に「対応済み（日付・コミット）」と追記する。

重要度の目安:

| 区分 | 意味 |
|---|---|
| **A. すぐ直す** | 今のままでは動かない・再現できない |
| **B. 高** | 安全性や移行の確実さに関わる |
| **C. 中** | 保守性。放置すると次の変更で壊れやすい |
| **D. 低** | 記述の整理 |

## A. すぐ直す

### A-1. 設定ファイル名の参照と実ファイルが食い違っている

- **現状**: テンプレート 2 本の `CONFIG_FILE`・ドキュメント・テストは `config/blue-green/staging.yml` 形式（`<環境>.yml`）を参照しているが、実ファイルは `staging.deployment.yml` / `production.deployment.yml` のままである（コミット `ffaf130 Remove deployment` で参照だけが変わった）。
- **影響**: パイプラインのすべての CodeBuild が設定ファイルを見つけられずに失敗する。`tests/build_green_test.sh` など設定を読むテストも失敗する。
- **提案**: 参照に合わせてファイルを改名する（`git mv config/blue-green/staging.deployment.yml config/blue-green/staging.yml`、production も同様）。
- **工数**: 小。
- **対応済み（2026-10-06）**: 実運用の `development.yml` / `staging.yml` / `production.yml` は**このリポジトリでは管理せず、別のリポジトリで管理する**方針とした。手順書やテンプレートの参照（`<環境>.yml`）は実運用のファイルを指すものとしてそのまま残し、このリポジトリの `*.deployment.yml` は書き方の見本として `staging.example.yml` / `production.example.yml` に改名した（テストの入力もこちらへ向けた）。生成ツールのゴールデンファイル（`examples/config-blue-green-generation/blue-green.<環境>.expected.yml`）は役割が違うため統合しない。
- **残る確認事項**: パイプラインはソースのリポジトリ（`RepositoryId` / `CodeCommitRepositoryName`）から `config/blue-green/<環境>.yml` を読む。実運用の設定が別のリポジトリにあるなら、**パイプラインのソースはその設定を含むリポジトリにする**必要がある（このリポジトリのスクリプトと実運用の設定が 1 つのソースにそろっていること）。運用するリポジトリの構成に合わせて、`RepositoryId` の指し先を決める。

### A-2. Step 1 のゴールデンファイルの入力が Git に入っていない

- **現状**: `examples/blue-green-prereqs/input/` が未追跡で、コミット済みなのは出力（`output/prereqs-evaluation-report.md`）だけである。`tools/internal/prereqs` のゴールデン一致テストはこの入力を読む。
- **影響**: 新しく clone した環境では `go test ./...` が失敗し、サンプルも再生成できない。
- **提案**: 入力をコミットする（匿名化済みであることを確認してから）。
- **工数**: 極小。

### A-3. `examples/` にテスト用のデータと例が混ざっている

- **現状**: `examples/` に、見本（ドキュメントから参照）・テストの入力と正解データ・実運用で使う定義が混在し、名前から役割が読めない。A-2 の未追跡もここから起きた。
- **方針**: テストが読むものは `tests/fixtures/` に置いてテスト用と分かるようにし、`examples/` にはどのテストからも参照されない例だけを残す。
- **対応済み（2026-10-06）**: テスト専用だった `examples/cfn-shorthand` を `tests/fixtures/cfn-shorthand/` へ移した。あわせて、`scripts/internal/cfn` と `tools/internal/cfn` の fixture テストが相対パスの誤り（`../../` で `scripts/`・`tools/` を指していた）で**常にスキップされていた**のを直し、fixture が見つからなければ失敗するようにした。
- **残り**: 見本とテストを兼ねている `examples/blue-green-prereqs`・`examples/mysql84-parameter-generation`・`examples/config-blue-green-generation`（と、テストの入力になっている `config/blue-green/*.example.yml`）をどう分けるか。実運用の定義である `examples/rds-blue-green-deployment` を `examples/` の外へ出すか（参照ドキュメントが多いので `upgrade-flow-steps.md` のレビュー明けに）。

## B. 高

### B-1. パス・リンクの実在を検査するテストが無い

- **現状**: ドキュメント・テンプレート・buildspec の相互参照が密で、パスの書き換えが頻繁に起きているが、参照先が実在するかを確かめる仕組みが無い。A-1 もこれで見逃された。
- **提案**: `tests/` に次を検査するテストを足す。
  - Markdown の相対リンク（`[...](path)`）の参照先が実在する
  - ドキュメント・テンプレート・buildspec に書かれた `config/blue-green/...`・`scripts/...`・`tools/...`・`ci/...` のパスが実在する（`<環境>` などの置き換え部分は、実在する環境名で展開して確かめる）
- **工数**: 小〜中。

### B-2. テストを自動で回す仕組みが無い

- **現状**: `.github/workflows/` には手動起動の 3 本（BuildGreen / VerifyGreen / Switchover）しか無く、CodeBuild にもテスト用のプロジェクトは無い。`go test ./...` と `tests/*.sh` は人が手で回している。
- **提案**: push / pull request で `go vet`・`go test ./...`・`tests/*.sh`・B-1 のテストを回す workflow を 1 本足す。AWS へは接続しないので、認証情報は要らない。あわせて、テストを一括で実行する入口（`tests/run_all.sh` など）を用意すると、ローカルと CI で同じものを使える。
- **工数**: 小。

### B-3. `ProtectedRdsResourceArns` の既定が「全体」になっている

- **現状**: パイプラインのロールに変更系の RDS 権限（スナップショット作成・Blue/Green 作成）を付ける範囲を決めるパラメータだが、既定値は空である。空のとき、**アカウント・リージョン内のすべての DB インスタンスとスナップショット**が対象になる。`pipeline-stack.sh` の既定も空である。
- **影響**: 指定を忘れると、移行対象以外の DB に対しても変更系の権限を持つパイプラインができる。
- **提案**: 未指定ではデプロイできないようにする（既定値を無くして必須にする、または `pipeline-stack.sh up` で空なら止める）。全体を対象にしたい場合は、`*` を明示的に書かせる。
- **工数**: 小。

### B-4. Step 6（Green のヘルスチェック）が未実装

- **現状**: `docs/upgrade-flow-steps.md` で「CI（AWS API）＋ローカル（DB 接続）」と設計されているが、実装が無い。切替後の確認は手作業に頼っている。
- **提案**: 設計どおり 2 つに分けて実装する。AWS API で取れる部分（エンドポイント・インスタンスの状態・CloudWatch メトリクスの切替前後比較）は `scripts/` の Ruby と Go のレポート生成で、DB 接続を伴う部分は `tools/` の Go で行う。`upgrade-flow-steps.md` はレビュー中なので、Step の番号と内容は変えずに実装だけを足す。
- **工数**: 中〜大。

### B-5. 移行作業の記録（アーティファクト）の保全

- **現状**: 検証レポート（ゲート③の判断材料）や収集した JSON はアーティファクトバケットに入る。`pipeline-stack.sh down` はバケットを中身ごと削除する（確認の表示はある）。
- **影響**: スタックを片付けると、移行の証跡が消える。
- **提案**: `down` で削除する前に、バケットの中身をローカルへ取り出す（`aws s3 sync`）手順を組み込むか、証跡を別の保管先（記録用のバケットや社内の文書管理）へ移す運用を決める。
- **工数**: 小。

## C. 中

### C-1. CodeBuild イメージ `standard:7.0` の先行き

- **現状**: `standard:8.0` に切り替えると ReadApprovals だけが完了せずにタイムアウトしたため、7.0 に戻している。原因は未特定で、そのプロジェクトにしか無い `exported-variables` が疑わしい（経緯と切り分け手順は `ci/codebuild-codepipeline-setup.md`）。7.0 は Ubuntu 22.04 で、いずれ非推奨になる。
- **提案**: 次のどちらかを計画的に行う。
  1. 切り分けの実験（`exported-variables` の有無だけを変えた最小の buildspec を 8.0 で比べる）を行い、8.0 と `exported-variables` の組み合わせの問題なら AWS サポートへ報告する
  2. `exported-variables` を使わない設計へ変える。Switchover ステージの入場条件（`#{Approvals.SWITCHOVER_APPROVED}`）をやめ、承認の確認を `switchover.rb` に一本化する。代償として、`switchover: pending` でも手動承認のボタンが表示される（押しても何も起きない）
- **工数**: 1 は小、2 は中。

### C-2. `scripts/`（Ruby）と `tools/`（Go）の二重実装の一致テスト

- **現状**: フェーズ判定（`scripts/lib/migration_phase.rb` / `tools/internal/phase`）と設定の読み取り（`scripts/lib/deployment_config.rb` / `tools/internal/deployconfig`）は両側に同じ規則を持つが、一致を検査しているのは `cfn` だけである。
- **影響**: 片方だけ直すと、パイプライン（Step 3〜5）と後始末（Step 7）で、移行の進み具合の判定がずれる。
- **提案**: 入力と期待値の表（YAML か JSON）を 1 つ置き、Ruby と Go の両方のテストがそれを読んで検査する。
- **工数**: 小〜中。

### C-3. `codepipeline.yml`（all-in-one でない方）の扱い

- **現状**: `codepipeline-all-in-one.yml` に比べて遅れている。環境に `development` が無い、`Prepare`（承認の読み取り・構築前チェック）が無い、承認していない Switchover を飛ばす仕組みが無い。
- **提案**: 使う予定が無ければ廃止し、ドキュメントの言及を all-in-one に寄せる。使うなら all-in-one と揃える。
- **工数**: 廃止なら小、揃えるなら中。

### C-4. `docs/upgrade-flow-steps.md` の古い記述（レビュー明けに）

- **現状**: レビュー中のため内容を変えていない。次が現状と合っていない。
  - Step 1 のコマンドが `scripts/precheck.sh`（現在は `tools/` の Go コマンド）
  - Step 7 が「未実装」（`tools/cleanup` で実装済み）、Step 7 の実行形態
  - 0-1-06 を手で確かめるという補足（`collect_blue_mysql_state` で自動判定できる）
  - Step 1・2 の実装リンクの表示名が `scripts/...`（リンク先は `tools/`）
- **提案**: レビューが明けたら、Step の番号は変えずにこれらを直す。
- **工数**: 小。

### C-5. `development` 環境の設定ファイルが無い

- **現状**: テンプレートの `EnvironmentName` では `development` を選べるが、`config/blue-green/` に development の設定ファイルが無い（カタログ `config/migration-catalog.yml` には定義がある）。
- **提案**: development のアカウントで `collect_rds_instance_inventory` → `generate_blue_green_config` を実行して生成する（A-1 のファイル名に合わせる）。
- **工数**: 小。

## D. 低

### D-1. `docs/references/mysql-timezone.md` の古い案内

- **現状**: 実効値の収集について「`--mysql-user` を指定する」と案内している。今は設定ファイルの `mysql_verification` で有効にするのが正しい手順である（`--mysql-user` も残してはいる）。
- **提案**: `mysql_verification` での指定を主にした案内へ直す。
- **工数**: 極小。

### D-2. 過去の記録・検討メモと現状との乖離

- **現状**: `auxiliary/inline-python-reduction-report.md` や `docs/decisions/structure-review-proposal.md` は当時のまま（シェルのスクリプト名など）で、現状と大きく違う。
- **提案**: 冒頭に「〇〇時点の記録で、現状とは異なる」と明記するか、アーカイブ用のディレクトリへ移す。
- **工数**: 極小。

## 検討して見送ったもの（記録）

| 案 | 見送った理由 |
|---|---|
| 使われていないオプション（`--profile`・`--runtime-values-file`・`BUILD_APPROVED`）の削除 | シェルの削減効果が小さい |
| BuildReportTool を BuildGreen と並列に動かす | 縮むのは 30 秒程度。準備が失敗したなら AWS に何も触れていない、という性質を優先する |
| `scripts/resolve_go_module_root.sh` の Ruby 化 | BuildReportTool のローカル検証イメージ `golang:1.25` が Ruby を持たない |
| CodeBuild イメージを `standard:8.0` へ | ReadApprovals がタイムアウトするため（C-1） |
