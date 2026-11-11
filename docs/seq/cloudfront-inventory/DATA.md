# CloudFront ディストリビューションの棚卸し: 結果データ

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

## レコード: `cloudfront_distribution`

1 ディストリビューションにつき 1 行。

| 項目 | 内容 | 元にした API の値 |
|---|---|---|
| `region` | 常に `global` |  |
| `distribution_id` / `arn` / `domain_name` | ID・ARN・CloudFront のドメイン名 | ListDistributions |
| `aliases` | 代替ドメイン名（CNAME） | `Aliases.Items` |
| `status` / `enabled` / `comment` / `staging` | 状態・有効か・コメント・ステージング用か |  |
| `price_class` / `http_version` / `is_ipv6_enabled` | 料金クラス・HTTP の版・IPv6 |  |
| `web_acl_id` | 関連付けた WAF の Web ACL（ARN）。無ければ空文字 | `WebACLId` |
| `viewer_certificate` | `{acm_certificate_arn, cloudfront_default_certificate, minimum_protocol_version, ssl_support_method}` | `ViewerCertificate` |
| `origins` | `{id, domain_name, origin_path, origin_type, origin_access_control_id, origin_protocol_policy}`。origin_type は `s3` / `custom` / `vpc` | `Origins.Items` |
| `default_cache_behavior` | `{target_origin_id, viewer_protocol_policy, cache_policy_id, origin_request_policy_id, function_count, lambda_function_count}` | `DefaultCacheBehavior` |
| `cache_behavior_count` | 追加のキャッシュ動作の数 | `CacheBehaviors.Quantity` |
| `geo_restriction` | 地域制限（`none` / `allowlist` / `blocklist`） |  |
| `last_modified_time` | 最終更新日時 |  |

## 詳細取得: `config`

対象: `cloudfront_distribution`。一覧に入っていない設定。

| 項目 | 内容 |
|---|---|
| `default_root_object` | 既定のルートオブジェクト |
| `logging_enabled` / `logging_bucket` / `logging_prefix` | 標準ログの出力先 |
| `custom_error_response_count` | カスタムエラーページの数 |
| `continuous_deployment_policy_id` | 継続的デプロイのポリシー |

## 詳細取得: `tags`

対象: `cloudfront_distribution`。タグ（キー → 値）。
