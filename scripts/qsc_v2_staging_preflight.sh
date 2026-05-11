#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"
SMOKE_SQL="$ROOT_DIR/supabase/snippets/qsc_v2_staging_smoke_checks.sql"

if [[ ! -f "$PROJECT_REF_FILE" ]]; then
  echo "Missing project ref file: $PROJECT_REF_FILE" >&2
  exit 1
fi

PROJECT_REF="$(cat "$PROJECT_REF_FILE")"
echo "QSC v2 preflight"
echo "root: $ROOT_DIR"
echo "linked project ref: $PROJECT_REF"

if [[ ! -f "$SMOKE_SQL" ]]; then
  echo "Missing smoke SQL: $SMOKE_SQL" >&2
  exit 1
fi

run_query() {
  if [[ -n "${SUPABASE_DB_URL:-}" ]]; then
    supabase db query --db-url "$SUPABASE_DB_URL" -f "$1" -o json
  else
    supabase db query --linked -f "$1" -o json
  fi
}

run_query "$SMOKE_SQL"
