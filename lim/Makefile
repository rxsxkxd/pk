# テンプレートは template.yml（SAM の既定名）、設定は samconfig.toml。
# どちらも SAM CLI が自動で見つけるため、-t や --region の指定は要らない。

.PHONY: all test lint build build-cli build-MaskFunction deploy clean fmt run sample

all: fmt test build

fmt:
	gofmt -l -w .
	go vet ./...

test:
	go test ./... -race -count=1

# SAM が BuildMethod: go1.x で bootstrap を作るため、通常はこちらを使う。
build:
	sam build

# 動作確認・性能計測用のサンプル画像を testdata/ に生成する。
sample:
	go run ./cmd/gensample -out-dir testdata

# SAM (BuildMethod: makefile) から呼ばれるターゲット。
# ARTIFACTS_DIR は SAM が渡す。ldflags でシンボルとデバッグ情報を落とし、
# -trimpath でビルドパスを埋め込まないようにする。
build-MaskFunction:
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
		go build -trimpath -ldflags="-s -w" -tags lambda.norpc \
		-o $(ARTIFACTS_DIR)/bootstrap ./cmd/mask

# ローカル確認用 CLI。S3 を使わずに手元の画像をマスクできる。
# 出力先は既定で tmp/（.gitignore 済み）。
#   make run IN=testdata/idcard.jpg
#   make run IN=photo.jpg OUT=tmp/masked.jpg
IN  ?= testdata/idcard.jpg
OUT ?= tmp/masked.jpg
run:
	go run ./cmd/maskfile -out $(OUT) $(IN)

build-cli:
	go build -o build/maskfile ./cmd/maskfile

# 手元で Lambda 用バイナリだけ作る場合。
build-local:
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -o build/bootstrap ./cmd/mask

validate:
	sam validate

# 初回も 2 回目以降も同じ。設定は samconfig.toml にある。
#   make deploy           … dev
#   make deploy ENV=prod  … prod
ENV ?= default
deploy: build
	sam deploy --config-env $(ENV)

clean:
	rm -rf build .aws-sam tmp
