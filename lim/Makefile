.PHONY: all test lint build deploy clean fmt

all: fmt test build

fmt:
	gofmt -l -w .
	go vet ./...

test:
	go test ./... -race -count=1

# SAM が BuildMethod: go1.x で bootstrap を作るため、通常はこちらを使う。
build:
	sam build

# 手元で Lambda 用バイナリだけ作る場合。
build-local:
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -o build/bootstrap ./cmd/mask

validate:
	sam validate --lint

deploy: build
	sam deploy --guided

clean:
	rm -rf build .aws-sam
