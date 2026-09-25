# 実装言語の方針

> 位置づけ: **採択済みの方針**である。[structure-review-proposal.md](structure-review-proposal.md) 論点1（実装言語の統一）に対する結論のうち、言語の役割分担について決めた部分をここに記録する。

決定日: 2026-09-14

## 結論

| 対象 | 言語 | 理由 |
|---|---|---|
| **プログラム**（レポート生成、RDS インベントリ収集、Blue/Green 設定生成、CloudFormation テンプレート読み取り） | **Go** | 単一の静的バイナリで配布でき、実行側にランタイムを要求しない。単体テストを書ける |
| **設定 YAML の読み取り**（`scripts/lib/deployment_config.rb`。シェルからはコマンドとして呼ぶ） | **Ruby** | YAML（psych）が標準ライブラリで、gem の追加導入が不要。ビルド成果物も要らない |
| AWS 応答などの JSON の取り出し・生成 | jq | CodeBuild の managed image と GitHub Actions のランナーに同梱されている |
| 手順の実行順序・AWS CLI の呼び出し | Bash | 収集と判定を分離する構成（`CLAUDE.md`）に合わせる |

**新しいプログラムは Go で書く。**既存の Ruby は、**テスト可能性が問題になったものから順に移す**。一律の移行は目的ではない。

**「Ruby を消す」ことは目標にしない。**設定 YAML の読み取り（`scripts/lib/deployment_config.rb`）が Ruby ランタイムを要求し続けるため、`.rb` を全廃してもランタイム依存は消えない。移行の動機は依存削減ではなく**テスト可能性**である。

### 対象外とするもの

**多言語であること自体に意味があるコードは移行しない。** `examples/mysql-timezone-replication/probe/` は、`time_zone` の扱いがドライバによって違うことを確かめるための検証装置であり、Go・Ruby・Python の 3 実装が並ぶことが結論の根拠である（`probe/reports/summary.md`）。Go に寄せると検証が成立しない。

## なぜレポート生成を Go に残すのか

**Step 4 の MySQL 実効値収集は、リモート（CodeBuild）では成立しない可能性がある。** Green DB へ到達するには CodeBuild を VPC 内へ配置する必要があり、VPC・サブネット・セキュリティグループ・NAT の用意が別途要る。運用上それが難しい場合、**MySQL 接続を伴う確認はローカルから行い、レポート出力までをローカルで完結させる**フローになる。

この前提では、レポート生成器の主な実行主体はローカルである。**担当者のマシンで動かすものは、ランタイムを要求せず単一バイナリを配れる Go が適する。**

以前は逆の判断をしていた。Go 版は「CodeBuild に Ruby ランタイムを置かないため」に存在しており、設定 YAML の読み取りが Ruby になって CodeBuild に Ruby が入った時点では、Go 版の存在理由は薄れて見えた。**実行主体がローカルへ移ることで前提が変わり、判断も変わった。**

## Step 4 は同じ Go プログラムで 2 つの実行形態を賄う

レポート生成器は `--runtime-values` を**任意**の引数として受け取る。**リモートとローカルで別のプログラムを持たない。**

| 実行形態 | MySQL 接続 | 渡す引数 | レポートの「MySQL 実効値」列 |
|---|---|---|---|
| リモート（CodeBuild／GitHub Actions） | しない | `--runtime-values` を渡さない | `未収集` |
| ローカル | する | `--runtime-values <収集結果 JSON>` | 収集した実効値 |

**CodeBuild ではビルドと実行を別ステージに分けている。**`BuildReportTool` が Go でビルドして artifact へ出し、`VerifyGreen` はそれを受け取って実行する。VerifyGreen は Green DB へ到達するため VPC 内へ置く可能性があるので、**外部ネットワークへの依存をそこへ持ち込まない**ためである。

**実効値の有無で変わるのはこの列だけである。**パラメータグループのドリフト判定・Green の構成確認・レプリカ同期の判定はいずれも AWS API から取得した値で行うため、リモートでも判定内容は変わらない。この性質は `tests/cfn_shorthand_test.sh` が両形態のレポートを突き合わせて固定している。

## この方針に沿って実施したこと

- **`generate_green_verification_report.rb`（161 行）を削除し、Go 版に一本化した。**`verify_green.sh` は `GREEN_REPORT_GENERATOR` 未指定なら一時ファイルへ自分でビルドする。削除前に、Ruby 版と Go 版のレポートが全文一致することを確認している
- **`tests/test_generate_blue_green_config.sh` のアサーションを Python から Ruby へ移した。**これで**移行フローの実行経路とテストから Python が消えた**（残る Python は下記の対象外のものだけ）。移した後、意図的に壊した入力でアサーションが実際に落ちることを 4 パターン確認している
- **CloudFormation 短縮記法の実装を `internal/cfn` へ集約した。**Go 版レポート生成器が自前実装を持っていたのは、GitHub Actions が `.go` 1 ファイルだけを Docker でビルドしていたためである。GitHub Actions も CodeBuild と同じ `go build` に変えたことで制約が消え、**`ci/Dockerfile.green-verification-report` も削除した**（3 箇所 → 1 箇所）
  - 追記（2026-09-15）: **`scripts/` と `tools/` で Go のライブラリを共有しない**方針に変えたため、`internal/cfn` は `scripts/internal/cfn` と `tools/internal/cfn` の 2 本になった（1 箇所 → 2 箇所）。CI から到達する側と人が実行する側を独立させることを優先した判断である。同一内容の複製なので、**片方を直したらもう片方へ同じ変更を入れる**。ずれると `tests/cfn_shorthand_test.sh` が落ちる

## 残っていた Ruby プログラムの扱い

> 追記（2026-09-25）: **実施済み。`tools/` 配下はすべて Go へ移した。**`generate_mysql84_parameter_group` と `evaluate_blue_green_prereqs`（Ruby）に加え、`collect_blue_green_prereqs` / `collect_mysql84_parameter_inputs` / `cleanup`（Bash）も Go にした。移行前に、旧版と出力・終了コード・AWS CLI の呼び出しが一致することを確かめ（Step 2 はゴールデンファイルと、ルール・入力を変えた 22 通り、テンプレートの値の書き方 69 通り）、単体テストを `tools/internal/{prereqs,paramgen,cleanup}` に置いた。

以前の判断（参考）: `generate_mysql84_parameter_group` は「判定ロジックが重く単体テストが無い」ため移行を検討する、`evaluate_blue_green_prereqs` は「JSON を並べるだけ」なので急がない、としていた。どちらも収集スクリプトから直接呼ばれておらず、移行しても呼び出し側の改修は案内文の書き換えで済んだ。
