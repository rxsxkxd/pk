# Run from this directory. The Go module root is ../ (shared templates/ and testdata/).
# Each entry in PACKAGES is a separate Lambda deployment package: go/cmd/<name> → bin/<name>.zip.
PACKAGES := ticketqr exampleqr
BIN      := bin

.PHONY: test run run-example build clean

test:
	cd .. && go vet ./... && go test ./...

run:
	cd .. && go run ./go/cmd/ticketqr

run-example:
	cd .. && go run ./go/cmd/exampleqr

# Lambda (provided.al2023, arm64): bin/<name>.zip containing a single "bootstrap".
build: $(PACKAGES:%=$(BIN)/%.zip)

$(BIN)/%.zip: FORCE
	mkdir -p $(BIN)/$*
	cd .. && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -trimpath -ldflags='-s -w' \
		-o go/$(BIN)/$*/bootstrap ./go/cmd/$*
	cd $(BIN)/$* && rm -f ../$*.zip && zip -q ../$*.zip bootstrap

clean:
	rm -rf $(BIN)

FORCE:
