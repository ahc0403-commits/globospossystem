#!/usr/bin/env bash
set -euo pipefail

: "${SUPABASE_URL:?Missing SUPABASE_URL for Flutter web build}"
: "${SUPABASE_ANON_KEY:?Missing SUPABASE_ANON_KEY for Flutter web build}"

FLUTTER_BIN="${FLUTTER_BIN:-}"
if [[ -z "$FLUTTER_BIN" ]]; then
  if [[ -x ./.flutter/bin/flutter ]]; then
    FLUTTER_BIN="./.flutter/bin/flutter"
  elif command -v flutter >/dev/null 2>&1; then
    FLUTTER_BIN="flutter"
  else
    echo "Missing Flutter. Expected ./.flutter/bin/flutter or flutter in PATH." >&2
    exit 1
  fi
fi

"$FLUTTER_BIN" build web --release \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
  --dart-define=FIREBASE_API_KEY="${FIREBASE_API_KEY:-}" \
  --dart-define=FIREBASE_APP_ID="${FIREBASE_APP_ID:-}" \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID="${FIREBASE_MESSAGING_SENDER_ID:-}" \
  --dart-define=FIREBASE_PROJECT_ID="${FIREBASE_PROJECT_ID:-}" \
  --dart-define=FIREBASE_WEB_VAPID_KEY="${FIREBASE_WEB_VAPID_KEY:-}" \
  --no-wasm-dry-run
