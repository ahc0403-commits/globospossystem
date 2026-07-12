#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
PSQL_LOG="$TMP_DIR/psql.log"
REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"
SECRET='wrapper-test-secret'
REF_EXISTED=0

if [[ -f "$REF_FILE" ]]; then
  REF_EXISTED=1
  cp "$REF_FILE" "$TMP_DIR/project-ref.original"
fi

cleanup() {
  if [[ "$REF_EXISTED" == 1 ]]; then
    mkdir -p "$(dirname "$REF_FILE")"
    cp "$TMP_DIR/project-ref.original" "$REF_FILE"
  else
    rm -f "$REF_FILE"
    rmdir "$ROOT_DIR/supabase/.temp" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$(dirname "$REF_FILE")"
printf '%s\n' 'ynriuoomotxuwhuxxmhj' > "$REF_FILE"
cat > "$TMP_DIR/pos.env" <<EOF
SUPABASE_ACCESS_TOKEN=test-token
EOF
chmod 600 "$TMP_DIR/pos.env"

cat > "$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
cat > "$FAKE_BIN/supabase" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'db dump --linked --schema public --dry-run' ]] || exit 91
cat <<EXPORTS
export PGHOST="aws-0-ap-southeast-1.pooler.supabase.com"
export PGPORT="5432"
export PGUSER="cli_login_test.ynriuoomotxuwhuxxmhj"
export PGPASSWORD="$SECRET"
export PGDATABASE="postgres"
EXPORTS
EOF
cat > "$FAKE_BIN/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'args=%s\n' "$*" >> "$PSQL_LOG"
[[ "${WRAPPER_FORCE_FAIL:-0}" != 1 ]] || exit 23
EOF
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/supabase" "$FAKE_BIN/psql"

export PATH="$FAKE_BIN:$PATH"
export SECRET PSQL_LOG

output="$(ENV_FILE="$TMP_DIR/pos.env" \
  bash "$ROOT_DIR/scripts/run_pos_production_sql.sh" \
  "$ROOT_DIR/scripts/preflight_photo_objet_interval_rebuild.sql" \
  'Photo interval preflight' 2>&1)"
[[ "$output" == *'PASS: Photo interval preflight'* ]]
[[ "$output" != *"$SECRET"* ]]
grep -q -- '--single-transaction' "$PSQL_LOG"
grep -q -- '--command SET ROLE postgres;' "$PSQL_LOG"
grep -q -- '--file .*preflight_photo_objet_interval_rebuild.sql' "$PSQL_LOG"

set +e
failed_output="$(WRAPPER_FORCE_FAIL=1 ENV_FILE="$TMP_DIR/pos.env" \
  bash "$ROOT_DIR/scripts/run_pos_production_sql.sh" \
  "$ROOT_DIR/scripts/preflight_photo_objet_interval_rebuild.sql" \
  'Photo interval forced failure' 2>&1)"
failed_status=$?
set -e
[[ "$failed_status" -ne 0 ]]
[[ "$failed_output" != *'PASS: Photo interval forced failure'* ]]
[[ "$failed_output" != *"$SECRET"* ]]

printf 'PASS: POS production SQL wrapper target pinning and fail-fast behavior\n'
