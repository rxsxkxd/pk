# API Gateway の API の棚卸し: 結果データ

出力は 1 行に 1 レコードの JSON（JSONL）。この文書では、レコードの種類ごとの項目と、詳細取得で足される項目を説明する。使い方は [`README.md`](./README.md) を参照。

## どのレコードにも入る項目

| 項目 | 内容 |
|---|---|
| `record_type` | レコードの種類（下の各節の見出し） |
| `account_id` | AWS アカウント ID |
| `region` | リージョン。サービスによっては、実行したリージョンではなくリソースのあるリージョンや `global` が入る（下の表に書く） |
| `collected_at` | 一覧取得をした日時（UTC） |
| `errors` | 取得に失敗したもの。`{operation, code, message}` のリスト |

詳細取得の出力には、さらに `details_collected_at`（詳細取得をした日時）と `details`（種類 → 結果）が足される。取れなかった種類は `details` の値が `null` になり、理由が `errors` に足される。

値が無い項目は `null`、リストの項目は空の配列 `[]` になる。日時は UTC の `YYYY-MM-DDTHH:MM:SSZ` にそろえている。項目の名前と順番は、5 つの実装で同じ。

## レコード: `apigateway_rest_api`

1 REST API につき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `api_id` / `name` / `description` | API の ID・名前・説明 | GetRestApis |
| `endpoint_types` / `vpc_endpoint_ids` | エンドポイントの種類（`REGIONAL` / `EDGE` / `PRIVATE`）と、プライベート API の VPC エンドポイント | `endpointConfiguration` |
| `api_key_source` | API キーの取り出し元 |  |
| `disable_execute_api_endpoint` | 既定のエンドポイントを無効にしているか |  |
| `has_resource_policy` | リソースポリシーがあるか | `policy` |
| `version` / `created_date` | 版と作成日時 |  |
| `tags` | タグ（キー → 値） | `tags` |

## レコード: `apigateway_v2_api`

1 HTTP / WebSocket API につき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `api_id` / `name` / `description` | API の ID・名前・説明 | GetApis |
| `protocol_type` | `HTTP` / `WEBSOCKET` |  |
| `api_endpoint` | 既定のエンドポイント |  |
| `disable_execute_api_endpoint` | 既定のエンドポイントを無効にしているか |  |
| `cors_enabled` | CORS の設定があるか | `CorsConfiguration` |
| `route_selection_expression` | ルートの選び方（WebSocket API で使う） |  |
| `created_date` | 作成日時 |  |
| `tags` | タグ（キー → 値） | `Tags` |

## 詳細取得: `stages`

対象: `apigateway_rest_api, apigateway_v2_api`。ステージ。

| 項目 | 内容 |
|---|---|
| `stage_name` / `deployment_id` | ステージ名とデプロイ ID |
| `auto_deploy` | 自動デプロイ（HTTP / WebSocket API だけ。REST API は `null`） |
| `tracing_enabled` / `cache_cluster_enabled` / `web_acl_arn` | X-Ray・キャッシュ・WAF（REST API だけ。HTTP / WebSocket API は `null`） |
| `access_log_destination` | アクセスログの出力先 |
| `last_updated_date` | 最終更新日時 |

## 詳細取得: `routes`

対象: `apigateway_rest_api, apigateway_v2_api`。ルートと、その行き先（統合）。

| 項目 | 内容 |
|---|---|
| `route` | REST API は `メソッド パス`（例: `GET /users`）、HTTP / WebSocket API はルートキー |
| `authorization_type` | 認可の方式 |
| `integration_type` / `integration_uri` / `connection_type` | 統合の種類・行き先・接続方式（`INTERNET` / `VPC_LINK`） |
