# Rails 6.1 以降の水平シャーディング

## 概要

**接続先の DB（シャード）を宣言しておき、フレームワークの機能として切り替えられる**仕組みである。どのテナントがどのシャードかの割り当て、シャードをまたぐ検索・JOIN、データの再配置は、アプリ側で用意する必要がある。

## バージョンごとに追加された機能

| バージョン | 追加された主な機能 |
|---|---|
| 6.0 | 複数 DB（垂直分割：テーブル群ごとに別 DB）、primary／replica の読み書き分離、`connects_to` と `connected_to(role:)`、リクエスト単位で読み書き先を自動で切り替えるミドルウェア |
| **6.1** | **水平シャーディング**：`connects_to shards:` と `connected_to(shard:, role:)`、抽象クラス単位で切り替えるための新しい接続ハンドリング（`legacy_connection_handling = false`） |
| 7.0 | `has_many :through` / `has_one :through` の **`disable_joins: true`**：別 DB にまたがる関連を、JOIN ではなくクエリ 2 本で解決する |
| 7.1 | **`ShardSelector` ミドルウェア**：リクエストからシャードを自動で選ぶ。あわせて `connected_to_all_shards`、`shard_keys`、`sharded?` が追加された |

> 細かい API はバージョンで変わっているため、採用するバージョンの Rails ガイド（Multiple Databases with Active Record）で確認する。

## 今回の構成に当てはめた例

### database.yml（200 シャードは ERB で生成する）

```yaml
production:
  license:
    <<: *default
    database: license_db
    migrations_paths: db/license_migrate
  <% Tenant.list.each do |t| %>   # 実際は YAML や環境変数から読み込む
  tenant_<%= t.key %>:
    <<: *default
    host: <%= t.host %>
    database: <%= t.db_name %>
    migrations_paths: db/tenant_migrate
  <% end %>
```

### モデル側の宣言

```ruby
class LicenseRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :license }
end

class TenantRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to shards: Tenant.list.to_h { |t|
    [t.key.to_sym, { writing: :"tenant_#{t.key}" }]
  }
end

class UserAction < TenantRecord; end   # 行動履歴
class License    < LicenseRecord; end
```

### テナントを指定した処理

```ruby
TenantRecord.connected_to(shard: :acme) do
  UserAction.where(user_id: ids).find_each { ... }
end
```

切り替わるのは `TenantRecord` 配下のモデルだけで、ブロックの中でも `License` はライセンス DB に接続したままになる。

### リクエストからシャードを自動で選ぶ（7.1 以降）

```ruby
# config/application.rb
config.active_record.shard_selector = { lock: true }   # リクエスト中は他シャードへの切り替えを禁止
config.active_record.shard_resolver = ->(request) {
  Tenant.find_by_subdomain!(request.subdomain).key.to_sym
}
```

統合管理システムのように URL やパラメータでテナントを指定する画面なら、リゾルバでそれを読む。

### テナントを横断する処理

```ruby
TenantRecord.connected_to_all_shards { ... }   # 7.1 以降。シャードを順に回るだけで、並列にはならない
```

実際のバッチでは、テナントごとにジョブを積み、ジョブの中で `connected_to(shard:)` するほうが適している（[04](04-batch-design.md)）。

### DB をまたぐ関連（7.0 以降）

```ruby
has_many :licenses, through: :subscriptions, disable_joins: true
```

内部でクエリを 2 本に分けて実行する。[02](02-architecture-direction.md) のパターン A（アプリ側で JOIN）を、関連として書けるようになる。

### マイグレーション

`db:migrate` は database.yml に書いた全 DB に順に実行され、`migrations_paths` でテナント用とライセンス用を分けられる。200 シャードあると時間がかかるため、デプロイ手順の中での扱い（デプロイと分けて実行するか、並列化するか）を決めておく。

## できないこと（自前で用意するもの）

| 項目 | 内容 |
|---|---|
| シャードをまたぐクエリ・JOIN | 自動では行われない。横断の検索は横断ストア（[03](03-cross-tenant-store.md)）かアプリ側での集約が必要 |
| キーによる自動ルーティング | `tenant_id` の値からシャードを選ぶ仕組みはない。必ず `connected_to` かリゾルバでシャードを指定する |
| シャードの動的な追加 | シャードは起動時の `connects_to` で確定する。テナント追加時は設定を更新して再起動（デプロイ）する運用が前提。実行時の追加は技術的には可能だが公式にサポートされた方法ではない |
| リバランス・データ移動 | 機能としてはない |
| 接続数の管理 | シャードごとに接続プールができる。接続は使うときに張られ `idle_timeout` で解放されるが、多くのシャードに触るワーカーでは「シャード数 × プロセス数」分の接続が開きうる。`max_connections` の見積もりと、必要なら RDS Proxy・同時実行数の制御が要る |

## 同じインスタンス上の別スキーマの場合（Q1）

シャーディング機能では、**同じインスタンス上でもシャードごとに別の接続プール**になる。200 スキーマが少数のインスタンスに載っている場合は、次の 2 案を比べる。

| 案 | 長所 | 短所 |
|---|---|---|
| シャーディング機能を使う | Rails の標準機能で書ける。将来インスタンスを分けてもコードが変わらない | 接続数が多くなる |
| インスタンス単位で 1 接続、テーブル名をスキーマ付きで指定 | 接続数が少ない | 自前の仕組みになる。インスタンスを分けるとコードの見直しが要る |

## まとめ

- Rails 7.1 以降に上げると、テナントの切り替え、DB をまたぐ関連、リクエストからのシャードの自動選択が標準機能で書けるため、[02](02-architecture-direction.md) の「接続の切り替え層」をほぼフレームワークに任せられる。
- テナント横断の検索・集計は Rails の機能では解決しない。横断ストアとバッチの fan-out は引き続き別に必要である。
