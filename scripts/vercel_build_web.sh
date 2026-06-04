#!/usr/bin/env bash
set -euo pipefail

: "${SUPABASE_URL:?Missing SUPABASE_URL for Flutter web build}"
: "${SUPABASE_ANON_KEY:?Missing SUPABASE_ANON_KEY for Flutter web build}"

./.flutter/bin/flutter build web --release \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
  --no-wasm-dry-run
