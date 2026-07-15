#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/web"

for file in \
  index.html \
  flutter_bootstrap.js \
  flutter_service_worker.js \
  main.dart.js; do
  [[ -f "$BUILD_DIR/$file" ]] || {
    printf 'ERROR: missing Flutter web build output: %s\n' "$file" >&2
    exit 1
  }
done

grep -q 'registration.unregister' "$BUILD_DIR/flutter_service_worker.js"
grep -q 'serviceWorkerVersion' "$BUILD_DIR/flutter_bootstrap.js"

for source in \
  /index.html \
  /flutter_bootstrap.js \
  /flutter_service_worker.js \
  /main.dart.js; do
  grep -q "\"source\": \"$source\"" "$ROOT_DIR/vercel.json"
done
grep -q 'public, max-age=0, must-revalidate' "$ROOT_DIR/vercel.json"
if grep -q '"source": "/assets/(.*)"' "$ROOT_DIR/vercel.json"; then
  printf 'ERROR: broad immutable asset cache policy is not approved.\n' >&2
  exit 1
fi

printf 'PASS: Flutter 3.41.6 shell rollover and Vercel revalidation contract\n'
