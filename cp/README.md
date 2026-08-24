# Rails + React + Capybara (Docker)

DB を使わず、Rails が返す HTML に React を描画し、Capybara と Selenium/Chrome で表示を検証する最小構成です。

## 構成

| サービス | 役割 |
| --- | --- |
| `rails` | Rails 開発サーバーを常駐起動します。React のビルドと RSpec の実行もこのコンテナ内で行います。 |
| `selenium` | headless Chrome を起動し、Capybara のブラウザ操作を受け付けます。 |

Rails はホストの `3000` 番ポートを公開するため、アプリは `http://localhost:3000` で開けます。

spec 実行時には Rails コンテナ内で Capybara/Puma の一時テストサーバーが `3001` 番ポートに起動します。Chrome は Docker Compose のネットワーク上で `rails:3001` に接続します。

## 起動

```bash
docker compose up --build -d
docker compose ps
```

ブラウザで `http://localhost:3000` を開きます。

## spec の実行

起動済みの Rails コンテナ内で実行します。

```bash
docker compose exec -e RAILS_ENV=test rails bundle exec rspec
```

特定の spec だけを実行する場合:

```bash
docker compose exec -e RAILS_ENV=test rails bundle exec rspec spec/system/react_page_spec.rb
```

`docker compose exec` は `docker exec` と同様に起動済みコンテナでコマンドを実行しますが、コンテナ名を指定する必要がありません。

## 停止

```bash
docker compose down
```
