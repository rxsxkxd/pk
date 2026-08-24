# Rails + React + Capybara (Docker)

DB を使わず、Rails が返す HTML に React を描画し、Capybara と Selenium/Chrome で表示を検証する最小構成です。

## 実行

```bash
docker compose build
docker compose run --rm rails bundle exec rspec
```

Chrome は `selenium`、テスト実行と Capybara の Rails サーバーは `rails` コンテナで動きます。ブラウザから Rails テストサーバーへは Compose のサービス名 `rails` を使って到達します。
