#!/bin/sh
# Builds and tests the Rust stub inside an Amazon Linux 2023 (arm64) container; nothing is installed on
# the host. Cargo's registry and target directory are kept in Docker volumes between runs.
#   ./build.sh test    cargo test (uses ../testdata/cases.json)
#   ./build.sh lint    cargo fmt --check and cargo clippy (warnings are errors)
#   ./build.sh fmt     cargo fmt (rewrites the sources)
#   ./build.sh dev     local server on http://localhost:8090 (examples/local.rs; Ctrl-C to stop)
#   ./build.sh         cargo build --release and package dist/analyzer-stub.zip (bootstrap)
set -eu
cd "$(dirname "$0")"

image=ticketqr-analyzer-stub-rust-build
docker build --platform linux/arm64 -q -t "$image" -f Dockerfile.build . >/dev/null

run() {
  docker run --rm --platform linux/arm64 ${DOCKER_RUN_OPTS:-} \
    -v "$PWD/..:/work" -w /work/rust \
    -v ticketqr-cargo-registry:/root/.cargo/registry \
    -v ticketqr-analyzer-stub-rust-target:/work/rust/target \
    "$image" sh -c "$1"
}

case "${1:-build}" in
  test) run 'cargo test' ;;
  lint) run 'cargo fmt --check && cargo clippy --all-targets -- -D warnings' ;;
  fmt) run 'cargo fmt' ;;
  dev) DOCKER_RUN_OPTS="-it --init -p ${PORT:-8090}:8090" run 'cargo run --example local' ;;
  build)
    run 'cargo build --release && mkdir -p dist && cp target/release/analyzer-stub dist/bootstrap \
      && cd dist && rm -f analyzer-stub.zip && zip -q analyzer-stub.zip bootstrap && rm bootstrap'
    ls -l dist/analyzer-stub.zip ;;
  *) echo "usage: $0 [test|lint|fmt|dev|build]" >&2; exit 2 ;;
esac
