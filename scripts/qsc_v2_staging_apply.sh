#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"

MIGRATIONS=(
  "$ROOT_DIR/supabase/migrations/20260507000007_qsc_v2_check_scope_uniqueness.sql"
  "$ROOT_DIR/supabase/migrations/20260507000000_qsc_v2_core_additive_columns.sql"
  "$ROOT_DIR/supabase/migrations/20260507000001_qsc_v2_check_photos.sql"
  "$ROOT_DIR/supabase/migrations/20260507000002_qsc_v2_monitoring_views.sql"
  "$ROOT_DIR/supabase/migrations/20260507000003_qsc_v2_rpc_extensions.sql"
  "$ROOT_DIR/supabase/migrations/20260507000004_qsc_v2_get_qc_checks_extension.sql"
  "$ROOT_DIR/supabase/migrations/20260507000005_qsc_v2_template_rpc_extension.sql"
  "$ROOT_DIR/supabase/migrations/20260507000006_qsc_v2_office_read_model_views.sql"
)

if [[ ! -f "$PROJECT_REF_FILE" ]]; then
  echo "Missing project ref file: $PROJECT_REF_FILE" >&2
  exit 1
fi

PROJECT_REF="$(cat "$PROJECT_REF_FILE")"
echo "QSC v2 sequential apply"
echo "root: $ROOT_DIR"
echo "linked project ref: $PROJECT_REF"
echo "IMPORTANT: confirm this ref is STAGING before proceeding."
echo
read -r -p "Type APPLY_QSC_V2 to continue: " CONFIRM
if [[ "$CONFIRM" != "APPLY_QSC_V2" ]]; then
  echo "Aborted."
  exit 1
fi

run_file() {
  local file="$1"
  echo
  echo "==> Applying $(basename "$file")"
  if [[ -n "${SUPABASE_DB_URL:-}" ]]; then
    supabase db query --db-url "$SUPABASE_DB_URL" -f "$file"
  else
    supabase db query --linked -f "$file"
  fi
}

for file in "${MIGRATIONS[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing migration: $file" >&2
    exit 1
  fi
  run_file "$file"
  sleep 2
done

echo
echo "QSC v2 apply completed. Run scripts/qsc_v2_staging_preflight.sh for post-apply smoke."
