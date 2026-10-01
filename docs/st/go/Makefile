# Run from this directory. The Go module root is ../ (shared templates/ and testdata/).
FUNCS := issue-inline issue get-view get-qr
BIN   := bin

.PHONY: test run build clean

test:
	cd .. && go vet ./... && go test ./...

run:
	cd .. && go run ./go/cmd/local

# Lambda (provided.al2023, arm64): bin/<func>.zip containing a single "bootstrap" binary.
build: $(FUNCS:%=$(BIN)/%.zip)

$(BIN)/%.zip: FORCE
	mkdir -p $(BIN)/$*
	cd .. && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -trimpath -ldflags='-s -w' \
		-o go/$(BIN)/$*/bootstrap ./go/cmd/$*
	cd $(BIN)/$* && rm -f ../$*.zip && zip -q ../$*.zip bootstrap

clean:
	rm -rf $(BIN)

FORCE:
