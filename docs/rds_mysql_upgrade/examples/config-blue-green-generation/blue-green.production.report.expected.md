# Blue/Green 移行設定レビュー: production

移行カタログと RDS インベントリから生成した、切替前レビュー用の資料である。**可否は判定しない。** 判断材料を一か所に並べるだけである。

| 項目 | 値 |
|---|---|
| 環境 | production |
| リージョン | ap-northeast-1 |
| Blue/Green 実行単位（RDS インスタンス） | 2 |
| 接続定義 | 3 |
| アプリケーション | 2 |

## 移行元と移行先

エンジンバージョンは major.minor へ正規化して記録している（自動マイナーバージョンアップグレードの差分を判定へ持ち込まないため）。

| RDS インスタンス | 移行元 | 移行先 | インスタンスクラス | 移行先パラメータグループ |
|---|---|---|---|---|
| `example-service-test-production-audit-mysql80` | 8.0 / `example-service-test-production-audit-mysql80-v1` | 8.4.10 | db.r6g.large | `example-service-test-production-audit-mysql84-v1` |
| `example-service-test-production-mysql80` | 8.0 / `example-service-test-production-mysql80-v1` | 8.4.10 | db.r6g.xlarge | `example-service-test-production-mysql84-v1` |

移行先パラメータグループの元テンプレート（Step 2 の成果物）:

- `example-service-test-production-audit-mysql84-v1` ← `examples/mysql84-parameter-generation/output/example-service-test-production-audit-mysql84.yaml`
- `example-service-test-production-mysql84-v1` ← `examples/mysql84-parameter-generation/output/example-service-test-production-mysql84.yaml`

## 影響範囲（スキーマと接続元）

| RDS インスタンス | スキーマ | 接続元（アプリ.接続名） |
|---|---|---|
| `example-service-test-production-audit-mysql80` | `example_service_test_audit` | `example-service-test.audit`, `example-service-test-batch.primary` |
| `example-service-test-production-mysql80` | `example_service_test` | `example-service-test.primary` |

## time_zone の実値

Blue のパラメータグループから採取した実値である。`engine-default` はパラメータグループでは未設定（エンジン既定値）を意味する。

| RDS インスタンス | パラメータグループ | time_zone | 由来 |
|---|---|---|---|
| `example-service-test-production-audit-mysql80` | `example-service-test-production-audit-mysql80-v1` | Asia/Tokyo | user |
| `example-service-test-production-mysql80` | `example-service-test-production-mysql80-v1` | UTC | engine-default |

## Step 4 の MySQL 接続検証

`enabled: false` のときは Green DB へ接続せず、AWS API による検証だけを行う。**認証情報そのものはカタログにも生成結果にも無く、記録されるのは SSM パラメータ名だけである。**

| RDS インスタンス | 有効 | パスワード | ユーザー名 | ポート | TLS |
|---|---|---|---|---|---|
| `example-service-test-production-audit-mysql80` | 有効 | `/rds-bg-test/audit/mysql-password` | `/rds-bg-test/audit/mysql-user` | 3307 | 指定なし |
| `example-service-test-production-mysql80` | 有効 | `/rds-bg-test/mysql-password` | `/rds-bg-test/mysql-user` | 3306 | 指定なし |

## 要確認事項

- [ ] `example-service-test-production-audit-mysql80` は 2 アプリが同居している（example-service-test, example-service-test-batch）。切替の停止影響が全アプリへ及ぶ。関係者への周知範囲を確認する。
- [ ] `example-service-test-production-audit-mysql80` は time_zone を `Asia/Tokyo` に明示設定している（由来: user）。移行先 `example-service-test-production-audit-mysql84-v1` のテンプレートが同じ値になっているかを確認する（DEFAULT CURRENT_TIMESTAMP の datetime 列への影響: reference/mysql-timezone-problem-summary.md）。
- [ ] `actions` は生成時点ですべて `pending` である。実行を許可する操作だけを `approved` へ書き換える（CI は設定ファイルへ書き戻さない）。
- [ ] アプリケーションと接続先の対応、目標インスタンスクラス、パラメータグループの内容は自動判定していない。人がレビューする。
