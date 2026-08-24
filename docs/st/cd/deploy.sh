#!/usr/bin/env bash
# CD (cd/README.md 4, cd/UPDATE_ONLY.md 4): replace the Lambda code and the SPA files. The stacks, config.json and
# Parameter Store are not touched. Run from the root of the Test stage's output (go/bin/ticketqr.zip, web/dist/).
#
# Settings (environment): ARTIFACT_BUCKET, ARTIFACT_PREFIX (e.g. ticketqr/go), FUNCTION_NAMES (space separated),
# WEB_BUCKET, DISTRIBUTION_ID, COMMIT_ID, WEB_URL (optional: empty skips the smoke test).
set -euo pipefail

: "${ARTIFACT_BUCKET:?}" "${ARTIFACT_PREFIX:?}" "${FUNCTION_NAMES:?}" "${WEB_BUCKET:?}" "${DISTRIBUTION_ID:?}" "${COMMIT_ID:?}"
WEB_URL=${WEB_URL:-}

ZIP=go/bin/ticketqr.zip
DIST=web/dist
for f in "$ZIP" "$DIST/index.html"; do
  [ -f "$f" ] || { echo "missing $f (run from the Test stage's output)" >&2; exit 1; }
done

# Where things go in the artifact bucket. The API stack's ArtifactPrefix is $ARTIFACT_PREFIX/current, so updating
# the stack later keeps the code that runs now (cd/UPDATE_ONLY.md 3.1). releases/ and web-releases/ are for rollback.
release="$ARTIFACT_PREFIX/releases/$COMMIT_ID/ticketqr.zip"
current="$ARTIFACT_PREFIX/current/ticketqr.zip"
web_release="$ARTIFACT_PREFIX/web-releases/$COMMIT_ID/"

echo "== Lambda ($COMMIT_ID)"
aws s3 cp "$ZIP" "s3://$ARTIFACT_BUCKET/$release"
aws s3 cp "$ZIP" "s3://$ARTIFACT_BUCKET/$current"
for fn in $FUNCTION_NAMES; do
  aws lambda update-function-code --function-name "$fn" \
    --s3-bucket "$ARTIFACT_BUCKET" --s3-key "$current" --query CodeSha256 --output text
  aws lambda wait function-updated --function-name "$fn"
done

echo "== SPA"
# A copy for rollback (config.json is the environment's, not part of the build).
aws s3 sync "$DIST/" "s3://$ARTIFACT_BUCKET/$web_release" --exclude config.json
# assets/* first, index.html last: an old index.html never points to assets that are not there yet.
aws s3 sync "$DIST/" "s3://$WEB_BUCKET/" --delete --exclude index.html --exclude config.json \
  --cache-control 'public, max-age=31536000, immutable'
aws s3 cp "$DIST/index.html" "s3://$WEB_BUCKET/index.html" \
  --cache-control no-cache --content-type 'text/html; charset=utf-8'
aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths /index.html \
  --query Invalidation.Id --output text

if [ -n "$WEB_URL" ]; then
  echo "== Smoke test"
  curl -fsS -o /dev/null "$WEB_URL/"
  curl -fsS -o /dev/null "$WEB_URL/config.json"
fi
echo "deployed $COMMIT_ID"
