#!/bin/sh
# Packages the Lambda zip of the Python stub: dist/analyzer-stub.zip (index.py and analyzer.py; boto3 comes
# with the Lambda runtime). Same output path as the Node and Rust stubs.
set -eu
cd "$(dirname "$0")"
rm -rf dist
mkdir -p dist
zip -q dist/analyzer-stub.zip index.py analyzer.py
ls -l dist/analyzer-stub.zip
