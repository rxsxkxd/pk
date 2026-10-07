#!/bin/sh
# Start Garage, then set it up for E2E (E2E.md 3.3): one-node layout, the fixed test key, the buckets
# "web" and "evil" with website access. /tmp/ready marks the end of the setup (healthcheck).
set -eu

# Test-only credentials, shared with e2e/global-setup.ts. Not secrets.
KEY_ID=GK00000000000000000000e2e0
SECRET=e2e0000000000000000000000000000000000000000000000000000000000000

garage server &
GARAGE_PID=$!
trap 'kill "$GARAGE_PID"; wait "$GARAGE_PID"; exit 0' TERM INT

until garage status >/dev/null 2>&1; do sleep 0.2; done

NODE_ID=$(garage node id -q | cut -d@ -f1)
garage layout assign -z e2e -c 1G "$NODE_ID"
garage layout apply --version 1
garage key import --yes -n e2e "$KEY_ID" "$SECRET"
for bucket in web evil; do
  garage bucket create "$bucket"
  garage bucket allow --read --write --owner "$bucket" --key e2e
  garage bucket website --allow "$bucket"
done

touch /tmp/ready
echo "storage ready"
wait "$GARAGE_PID"
