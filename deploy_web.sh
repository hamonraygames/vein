#!/usr/bin/env bash
# Rebuilds the Godot Web export and pushes it to the live S3+CloudFront site.
#
# Godot's web export does NOT content-hash filenames (index.wasm/index.pck/
# index.js are the same name every build), so every asset here uses a short,
# revalidate-friendly cache instead of "immutable" — otherwise a redeploy
# leaves returning visitors' browsers running a stale WASM binary against a
# newer .pck (or vice versa) under an unchanged URL. The CloudFront
# invalidation at the end clears the CDN edge cache; the short max-age
# handles browser caches on the next visit.
set -euo pipefail

BUCKET="vein-web-393903547387"
DISTRIBUTION_ID="E1RKD9V8MS5VYU"
GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"

cd "$(dirname "$0")"

echo "==> Exporting Web build"
mkdir -p build/web
"$GODOT_BIN" --headless --path . --export-release "Web" build/web/index.html

echo "==> Syncing to s3://$BUCKET"
cd build/web
aws s3 sync . "s3://$BUCKET/" --delete \
  --exclude "*.wasm" --exclude "*.pck" --exclude "*.js" --exclude "*.png" --exclude "*.html" \
  --cache-control "public, max-age=3600, must-revalidate"

aws s3 cp index.wasm "s3://$BUCKET/index.wasm" \
  --content-type "application/wasm" --cache-control "public, max-age=3600, must-revalidate"
aws s3 cp index.pck "s3://$BUCKET/index.pck" \
  --content-type "application/octet-stream" --cache-control "public, max-age=3600, must-revalidate"
for f in index.js index.audio.worklet.js index.audio.position.worklet.js; do
  aws s3 cp "$f" "s3://$BUCKET/$f" \
    --content-type "application/javascript" --cache-control "public, max-age=3600, must-revalidate"
done
for f in index.png index.icon.png index.apple-touch-icon.png; do
  aws s3 cp "$f" "s3://$BUCKET/$f" \
    --content-type "image/png" --cache-control "public, max-age=3600, must-revalidate"
done
aws s3 cp index.html "s3://$BUCKET/index.html" \
  --content-type "text/html" --cache-control "public, max-age=60"

echo "==> Invalidating CloudFront cache"
aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/*"

echo "==> Done: https://$(aws cloudfront get-distribution --id "$DISTRIBUTION_ID" --query 'Distribution.DomainName' --output text)"
