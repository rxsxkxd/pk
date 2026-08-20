# Playwright JavaScript を実行する Node.js 24 の Debian Bookworm イメージ。
FROM node:24-bookworm

# E2E テストのソースコードを置くコンテナ内作業ディレクトリ。
WORKDIR /tests

# テスト依存関係の定義ファイルを先にコピーしてレイヤーキャッシュを活用する。
COPY package.json ./
# Playwright Test を含む Node.js の依存パッケージをインストールする。
RUN npm install --no-audit --no-fund
# Chromium 本体と実行に必要な OS 依存パッケージをインストールする。
RUN npx playwright install --with-deps chromium

# Playwright の設定ファイルをコンテナへコピーする。
COPY playwright.config.js ./
# テストコードをコンテナへコピーする。
COPY tests ./tests

# コンテナ起動時に Playwright テストを実行する。
CMD ["npm", "test"]
