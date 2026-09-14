# CloudFormation (SAM) の定義ファイル。SAM CLI の既定は template.yaml なので
# 명示的に -t で渡す必要がある。
TEMPLATE := cloudformation.yaml

.PHONY: all test lint build build-cli deploy clean fmt run sample

all: fmt test build

fmt:
	gofmt -l -w .
	go vet ./...

test:
	go test ./... -race -count=1

# SAM が BuildMethod: go1.x で bootstrap を作るため、通常はこちらを使う。
build:
	sam build -t $(TEMPLATE)

# 動作確認・性能計測用のサンプル画像を testdata/ に生成する。
sample:
	go run ./cmd/gensample -out-dir testdata

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
	sam validate -t $(TEMPLATE) --lint

deploy: build
	sam deploy --guided

clean:
	rm -rf build .aws-sam tmp
