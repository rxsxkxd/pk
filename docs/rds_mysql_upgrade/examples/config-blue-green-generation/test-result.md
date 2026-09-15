# Blue/Green 設定生成支援ツール: テスト結果

実行日: 2026-09-11

実 AWS へは接続していない。PATH 上の `aws` をダミーコマンドへ差し替え、下の fixture を返している。ダミーは `describe-db-instances` と `describe-db-parameters` を返し分け、**それ以外の API を呼ぶと `exit 64` で失敗する**（読み取り以外を呼んでいないことの担保）。

## 入力（fixture）

| ファイル | 内容 |
|---|---|
| [migration-catalog.test.yml](migration-catalog.test.yml) | 2 アプリ。development で 2 接続が 1 インスタンスに同居、production の audit だけ `mysql_verification` を個別上書き、`target` の一部省略を含む |
| [rds-instance-inventory.test.json](rds-instance-inventory.test.json) | `describe-db-instances` のダミー応答（6 インスタンス、すべてダミー RDS ID） |
| [describe-db-parameters/](describe-db-parameters/) | パラメータグループごとの `describe-db-parameters` ダミー応答（6 件）。`time_zone` は `engine-default` と `user` の両ケース |
| [target-parameter-groups/](target-parameter-groups/) | 移行先（8.4）パラメータグループの CloudFormation テンプレート 5 件。`time_zone` の適用予定値として **一致・差異・`!Ref`（比較不能）** の 3 パターンを含む |

## ① 収集: `collect_rds_instance_inventory`

呼び出した AWS CLI は 7 回。`describe-db-instances` が 1 回と、**パラメータグループごとにちょうど 1 回**の `describe-db-parameters` である（同じグループを複数インスタンスが共有していても 1 回）。

```text
--region ap-northeast-1 --profile test-readonly rds describe-db-instances --output json
--region ap-northeast-1 --profile test-readonly rds describe-db-parameters --db-parameter-group-name example-service-test-development-mysql80-v1 --output json
--region ap-northeast-1 --profile test-readonly rds describe-db-parameters --db-parameter-group-name example-service-test-development-audit-mysql80-v1 --output json
--region ap-northeast-1 --profile test-readonly rds describe-db-parameters --db-parameter-group-name example-service-test-staging-mysql80-v1 --output json
--region ap-northeast-1 --profile test-readonly rds describe-db-parameters --db-parameter-group-name example-service-test-staging-audit-mysql80-v1 --output json
--region ap-northeast-1 --profile test-readonly rds describe-db-parameters --db-parameter-group-name example-service-test-production-mysql80-v1 --output json
--region ap-northeast-1 --profile test-readonly rds describe-db-parameters --db-parameter-group-name example-service-test-production-audit-mysql80-v1 --output json
```

収集結果は `aws_region: ap-northeast-1`、`DBInstances` 6 件、`ParameterGroups` 6 件。`DBInstances` は応答をそのまま保持し、収集器が使わない項目（`ParameterApplyStatus` など）も落とさない。採取対象は `CollectedParameters`（現在は `time_zone` のみ）で、`binlog_format` など対象外のパラメータは保存しない。

| パラメータグループ | time_zone | 由来 |
|---|---|---|
| `example-service-test-development-mysql80-v1` | UTC | engine-default |
| `example-service-test-development-audit-mysql80-v1` | UTC | engine-default |
| `example-service-test-staging-mysql80-v1` | UTC | engine-default |
| `example-service-test-staging-audit-mysql80-v1` | Asia/Tokyo | user |
| `example-service-test-production-mysql80-v1` | UTC | engine-default |
| `example-service-test-production-audit-mysql80-v1` | Asia/Tokyo | user |

## ② YAML 生成: `generate_blue_green_config`

| 環境 | 接続定義 | 生成した deployment | ゴールデン |
|---|---|---|---|
| development | 2 | 1（2 接続が 1 インスタンスに同居） | [blue-green.development.expected.yml](blue-green.development.expected.yml) |
| staging | 2 | 2 | [blue-green.staging.expected.yml](blue-green.staging.expected.yml) |
| production | 3 | 2（audit に 2 アプリが同居） | [blue-green.production.expected.yml](blue-green.production.expected.yml) |

| 確認項目 | 結果 |
|---|---|
| 生成単位 | PASS。`services` のキーは RDS インスタンス識別子。同じ `rds_instance` を指す接続は 1 deployment へまとめ、`schemas` を昇順で集約 |
| 収集リージョン | PASS。収集時の `--region` をインベントリの `aws_region` 経由で生成結果へ引き継ぐ（カタログには書かない） |
| `target` の省略 | PASS。`engine_version` 省略時は共通ターゲット 8.4.11、`db_instance_class` 省略時は Blue の実値を踏襲 |
| 移行元バージョン | PASS。`8.0.43` / `8.0.46` を `8.0` へ正規化（自動マイナーバージョンアップグレードの差分を判定へ持ち込まない） |
| `mysql_verification` の継承 | PASS。ルート既定値を接続配下がキー単位で上書き（production の audit だけ別パラメータ・ポート 3307） |
| 認証情報 | PASS。`user` / `password` はカタログにも生成結果にも現れない。記録は SSM パラメータ名だけ |
| `source_db_parameters` | PASS。Blue のパラメータグループの実値を、パラメータ名をキーに `value` / `source` で出力（確認用。実行スクリプトは読まない） |
| 承認状態 | PASS。`build`、`switchover`、`cleanup` はすべて `pending` |
| 出力先 | PASS。テストは `mktemp` の一時ディレクトリへ出力し、`config/blue-green/{staging,production}.deployment.yml` を変更しない |

## ③ レポート生成: `generate_blue_green_config_report`

YAML 生成とは別コマンドで、同じ入力から Markdown を出す。**設定ファイルは書き換えない。**

| 環境 | ゴールデン |
|---|---|
| development | [blue-green.development.report.expected.md](blue-green.development.report.expected.md) |
| staging | [blue-green.staging.report.expected.md](blue-green.staging.report.expected.md) |
| production | [blue-green.production.report.expected.md](blue-green.production.report.expected.md) |

**現在のパラメータグループの実値と、移行先テンプレートの適用予定値を直接突き合わせる。** fixture は 3 パターンを網羅している。

| 環境 | RDS インスタンス | 現在 | 由来 | 適用予定 | 判定 |
|---|---|---|---|---|---|
| development | `...-development-mysql80` | UTC | engine-default | UTC | 一致 |
| staging | `...-staging-mysql80` | UTC | engine-default | UTC | 一致 |
| staging | `...-staging-audit-mysql80` | Asia/Tokyo | user | UTC | **差異** |
| production | `...-production-mysql80` | UTC | engine-default | Ref | 比較不能 |
| production | `...-production-audit-mysql80` | Asia/Tokyo | user | Asia/Tokyo | 一致 |

`!Ref` の項目は CloudFormation のパラメータ解決なしには実値が決まらないため、比較せず「比較不能」として示す（短縮記法は長形式へ正規化して読んでいる）。

要確認事項はこの突き合わせ結果から出る。production では次の 2 件。

- `...-production-audit-mysql80` は 2 アプリが同居している（切替の停止影響が両アプリへ及ぶ）
- `...-production-mysql80` の `time_zone` は移行先テンプレートで組み込み関数（Ref）になっており、実値が決まらない

staging では `time_zone` が `Asia/Tokyo` から `UTC` へ変わる旨が「意図した変更かを確認する」として挙がる。加えて、常に出る 2 件（`actions` が全 `pending`、自動判定していない範囲）が並ぶ。

## テストの実行

ロジックの単体テストは `tools/internal/{common,collect,generate,cfn,report}` にある。**すべて PASS。** AWS へは接続しない（`tools/internal/collect` は PATH 上の `aws` をダミーへ差し替えて引数の組み立てを検証する）。

```bash
go test ./...
```

上の ①〜③ を通した E2E テストは次で実行する。生成した YAML とレポートをゴールデンと突き合わせる。

```bash
tests/test_generate_blue_green_config.sh
```
