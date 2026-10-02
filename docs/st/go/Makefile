# Run from this directory. The Go module root is ../ (shared templates/ and testdata/).
BIN := bin

.PHONY: test run build clean

test:
	cd .. && go vet ./... && go test ./...

run:
	cd .. && go run ./go/cmd/ticketqr

# Lambda (provided.al2023, arm64): one package for every endpoint, bin/ticketqr.zip containing "bootstrap".
build:
	mkdir -p $(BIN)/ticketqr
	cd .. && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -trimpath -ldflags='-s -w' \
		-o go/$(BIN)/ticketqr/bootstrap ./go/cmd/ticketqr
	cd $(BIN)/ticketqr && rm -f ../ticketqr.zip && zip -q ../ticketqr.zip bootstrap

clean:
	rm -rf $(BIN)
