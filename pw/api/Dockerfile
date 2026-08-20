# Go 1.24 を使って API バイナリをビルドするステージ。
FROM golang:1.24-alpine AS build

# ソースコードを扱うコンテナ内の作業ディレクトリ。
WORKDIR /src

# 依存関係の定義ファイルだけを先にコピーしてレイヤーキャッシュを活用する。
COPY go.mod ./
# Go モジュールの依存関係を取得する。
RUN go mod download

# API のソースコードをビルドステージへコピーする。
COPY . .
# CGO を無効化した小さな API 実行バイナリを /api として生成する。
RUN CGO_ENABLED=0 go build -ldflags='-s -w' -o /api ./cmd/api
# Docker healthcheck 用の Go 実行バイナリを /healthcheck として生成する。
RUN CGO_ENABLED=0 go build -ldflags='-s -w' -o /healthcheck ./cmd/healthcheck

# 実行に必要な最小限の Alpine Linux イメージへ切り替える。
FROM alpine:3.21

# ビルドステージで生成した API バイナリだけをコピーする。
COPY --from=build /api /api
# ビルドステージで生成したヘルスチェック用バイナリをコピーする。
COPY --from=build /healthcheck /healthcheck

# API が待ち受けるコンテナ内ポートを文書化する。
EXPOSE 3000
# コンテナ起動時に API バイナリを実行する。
CMD ["/api"]
