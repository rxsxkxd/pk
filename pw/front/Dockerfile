# Vite dev server を動かす Node.js 22 の軽量イメージ。
FROM node:22-alpine

# フロントエンドのソースコードを置くコンテナ内作業ディレクトリ。
WORKDIR /app

# 依存関係の定義ファイルを先にコピーしてレイヤーキャッシュを活用する。
COPY package.json ./
# Vue、Vite、TypeScript などの依存パッケージをインストールする。
RUN npm install --no-audit --no-fund

# フロントエンドのソースコードをコンテナへコピーする。
COPY . .

# Vite dev server が待ち受ける標準ポートを文書化する。
EXPOSE 5173
# 外部の Docker ネットワークから接続できるよう Vite dev を起動する。
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0"]
