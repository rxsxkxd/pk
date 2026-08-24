# チケット QR（作業の決まり）

構成と設計は [README.md](README.md)・[DESIGN.md](DESIGN.md)。このディレクトリは、あとで専用のリポジトリとして切り出す前提で書く。

## ドキュメント

- 平易な日本語で書く
- 新しい文書はルートに置く。ただし CI の文書は `ci/`、CD の文書は `cd/` に置く
- 文書やコードのコメントに `docs/st` や `cd docs/st` を書かない。場所は「作業ディレクトリ」と書く（自明なら書かない）
- 未対応・未確認・未実装の事項は [OPEN_ITEMS.md](OPEN_ITEMS.md) だけにまとめ、ほかの文書には書かない。`notes/`・`web/notes/` のメモはそのままにする
- 用語: URL の署名は `sig`（QR 画像の URL に付けるもので、チケットやコードへの署名ではない）。チケットコードは「コード」、画面に出す文字列の文脈では「コード文字列」

## 実装

- API は Go が採用実装。Node.js 版は比較用で、説明は `node/` の中だけに書く（ルートの README には 1 行だけ）。SAM で Node.js 版をビルドできる状態は保つ
- 利用者の端末は古いものから最新のものまである。OS を上げる、写真の形式を変えるなど、利用者側の対応は期待できない前提で考える

## CI / CD とインフラ

- CI（GitHub Actions。コミットごとの単体テストだけ）は `ci/`
- CD（CodePipeline / CodeBuild。テンプレート・buildspec・スクリプト・文書）は `cd/`
- `infra/` に置く CI / CD のものは、最初の環境構築の手順書（[infra/CD_PIPELINE.md](infra/CD_PIPELINE.md)）だけ
- CloudFormation のパラメータには英語の `Description` と、その上の行に日本語のコメントを付ける。SG の説明（`GroupDescription` など）に `'` などの記号を使わない

## テスト

- 単体テストは外に通信しない（解析サーバーと `fetch` は偽物に差し替える）
- compose の E2E は既定では流さず、手順（[E2E_RUN.md](E2E_RUN.md)）を渡す。頼まれたときだけ流す
