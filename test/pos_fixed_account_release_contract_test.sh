#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="$ROOT_DIR/scripts/deploy_pos_production.sh"
SMOKE="$ROOT_DIR/scripts/smoke_fixed_pos_account_login.sh"
BOOTSTRAP="$ROOT_DIR/scripts/bootstrap_pos_master_account.ts"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

grep -Fq 'verify_allowed_production_origins' "$DEPLOY"
grep -Fq 'ALLOWED_ORIGINS must be exactly $LIVE_URL' "$DEPLOY"
grep -Fq 'FIXED_SMOKE_ACCOUNT_CODE' "$DEPLOY"
grep -Fq 'FIXED_SMOKE_PASSWORD' "$DEPLOY"
grep -Fq 'FIXED_ACCOUNT_SMOKE_SCRIPT' "$DEPLOY"
grep -Fq 'supabase functions deploy create_staff_user --project-ref "$POS_PROJECT_REF"' "$DEPLOY"
grep -Fq 'supabase functions deploy provision-fixed-pos-account' "$DEPLOY"
grep -Fq '"projectName"[[:space:]]*:[[:space:]]*' "$DEPLOY"
grep -Fq '"projectId"[[:space:]]*:[[:space:]]*' "$DEPLOY"
grep -Fq '"orgId"[[:space:]]*:[[:space:]]*' "$DEPLOY"
grep -Fq 'verify_remote_allowed_origin' "$DEPLOY"
grep -Fq 'access-control-allow-origin' "$DEPLOY"
grep -Fq 'never creates, recovers, resets, or rotates' "$SMOKE"
grep -Fq 'EXPECTED_FIXED_ACCOUNT_CODE' "$SMOKE"
grep -Fq 'POS_MASTER_EMAIL' "$BOOTSTRAP"
grep -Fq 'POS_MASTER_CURRENT_RUN_ROLLBACK_FAILED' "$BOOTSTRAP"
if grep -Eiq 'office|restaurant_office' "$BOOTSTRAP"; then
  printf 'bootstrap must not reference Office Auth\n' >&2
  exit 1
fi

cat >"$TMP_DIR/generic-smoke.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'email=%s code=%s args=%s\n' \
  "${PILOT_SMOKE_EMAIL:-}" "${EXPECTED_FIXED_ACCOUNT_CODE:-}" "$*"
EOF
chmod +x "$TMP_DIR/generic-smoke.sh"

dry_run="$({
  FIXED_SMOKE_ACCOUNT_CODE=bunsik_sm1 \
    PILOT_SMOKE_SCRIPT="$TMP_DIR/generic-smoke.sh" \
    bash "$SMOKE" --dry-run
} 2>&1)"
[[ "$dry_run" == *'bunsik_sm1@globos.world'* ]]
[[ "$dry_run" != *'dry-run-placeholder'* ]]

set +e
bad_code="$({
  FIXED_SMOKE_ACCOUNT_CODE='Bad Email' bash "$SMOKE" --dry-run
} 2>&1)"
bad_status=$?
set -e
[[ "$bad_status" -ne 0 ]]
[[ "$bad_code" == *'valid fixed account code'* ]]

printf 'PASS: POS bootstrap, fixed-account smoke, and production origin contracts\n'
