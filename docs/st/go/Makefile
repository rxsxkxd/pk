# Run from this directory (the Go module root). Shared test vectors are read from ../testdata.
# Each entry in PACKAGES is a separate Lambda deployment package: cmd/<name> → bin/<name>.zip.
PACKAGES := ticketqr exampleqr
BIN      := bin

.PHONY: test run run-example build clean

test:
	go vet ./... && go test ./...

run:
	go run ./cmd/ticketqr

run-example:
	go run ./cmd/exampleqr

# Lambda (provided.al2023, arm64): bin/<name>.zip containing a single "bootstrap".
build: $(PACKAGES:%=$(BIN)/%.zip)

$(BIN)/%.zip: FORCE
	mkdir -p $(BIN)/$*
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -trimpath -ldflags='-s -w' \
		-o $(BIN)/$*/bootstrap ./cmd/$*
	cd $(BIN)/$* && rm -f ../$*.zip && zip -q ../$*.zip bootstrap

clean:
	rm -rf $(BIN)

FORCE:
