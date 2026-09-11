# Blue/Green 移行設定レビュー: staging

移行カタログと RDS インベントリから生成した、切替前レビュー用の資料である。**可否は判定しない。** 判断材料を一か所に並べるだけである。

| 項目 | 値 |
|---|---|
| 環境 | staging |
| リージョン | ap-northeast-1 |
| Blue/Green 実行単位（RDS インスタンス） | 2 |
| 接続定義 | 2 |
| アプリケーション | 1 |

## 移行元と移行先

エンジンバージョンは major.minor へ正規化して記録している（自動マイナーバージョンアップグレードの差分を判定へ持ち込まないため）。

| RDS インスタンス | 移行元 | 移行先 | インスタンスクラス | 移行先パラメータグループ |
|---|---|---|---|---|
| `example-service-test-staging-audit-mysql80` | 8.0 / `example-service-test-staging-audit-mysql80-v1` | 8.4.10 | db.t4g.medium | `example-service-test-staging-audit-mysql84-v1` |
| `example-service-test-staging-mysql80` | 8.0 / `example-service-test-staging-mysql80-v1` | 8.4.10 | db.t4g.medium | `example-service-test-staging-mysql84-v1` |

移行先パラメータグループの元テンプレート（Step 2 の成果物）:

- `example-service-test-staging-audit-mysql84-v1` ← `examples/config-blue-green-generation/target-parameter-groups/example-service-test-staging-audit-mysql84.yaml`
- `example-service-test-staging-mysql84-v1` ← `examples/config-blue-green-generation/target-parameter-groups/example-service-test-staging-mysql84.yaml`

## 影響範囲（スキーマと接続元）

| RDS インスタンス | スキーマ | 接続元（アプリ.接続名） |
|---|---|---|
| `example-service-test-staging-audit-mysql80` | `example_service_test_audit` | `example-service-test.audit` |
| `example-service-test-staging-mysql80` | `example_service_test` | `example-service-test.primary` |

## パラメータの現状と適用予定値

「現在」は Blue のパラメータグループから採取した実値（`engine-default` はパラメータグループでは未設定＝エンジン既定値）。「適用予定」は移行先パラメータグループの CloudFormation テンプレート（Step 2 の成果物）が宣言している値である。

| RDS インスタンス | パラメータ | 現在 | 由来 | 適用予定 | 判定 |
|---|---|---|---|---|---|
| `example-service-test-staging-audit-mysql80` | `time_zone` | Asia/Tokyo | user | UTC | **差異** |
| `example-service-test-staging-mysql80` | `time_zone` | UTC | engine-default | UTC | 一致 |

突き合わせたテンプレート:

- `example-service-test-staging-audit-mysql84-v1` ← `examples/config-blue-green-generation/target-parameter-groups/example-service-test-staging-audit-mysql84.yaml`
- `example-service-test-staging-mysql84-v1` ← `examples/config-blue-green-generation/target-parameter-groups/example-service-test-staging-mysql84.yaml`

## Step 4 の MySQL 接続検証

`enabled: false` のときは Green DB へ接続せず、AWS API による検証だけを行う。**認証情報そのものはカタログにも生成結果にも無く、記録されるのは SSM パラメータ名だけである。**

| RDS インスタンス | 有効 | パスワード | ユーザー名 | ポート | TLS |
|---|---|---|---|---|---|
| `example-service-test-staging-audit-mysql80` | 有効 | `/rds-bg-test/mysql-password` | `/rds-bg-test/mysql-user` | 3306 | 指定なし |
| `example-service-test-staging-mysql80` | 有効 | `/rds-bg-test/mysql-password` | `/rds-bg-test/mysql-user` | 3306 | 指定なし |

## 要確認事項

- [ ] `example-service-test-staging-audit-mysql80` の `time_zone` が切替で `Asia/Tokyo` から `UTC` へ変わる。意図した変更かを確認する（DEFAULT CURRENT_TIMESTAMP の datetime 列への影響: reference/mysql-timezone-problem-summary.md）。
- [ ] `actions` は生成時点ですべて `pending` である。実行を許可する操作だけを `approved` へ書き換える（CI は設定ファイルへ書き戻さない）。
- [ ] アプリケーションと接続先の対応、目標インスタンスクラス、パラメータグループの内容は自動判定していない。人がレビューする。
