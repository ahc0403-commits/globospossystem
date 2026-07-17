#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly POS_PROJECT_REF="ynriuoomotxuwhuxxmhj"
PILOT_SMOKE_SCRIPT="${PILOT_SMOKE_SCRIPT:-$ROOT_DIR/scripts/smoke_pilot_login.sh}"
ACCOUNT_CODE="${FIXED_SMOKE_ACCOUNT_CODE:-}"
DRY_RUN=0

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/smoke_fixed_pos_account_login.sh [--dry-run]

Authenticates an already-provisioned fixed POS account and verifies its POS
profile. It never creates, recovers, resets, or rotates an account/password.

Required env for a real smoke:
  FIXED_SMOKE_ACCOUNT_CODE=<fixed code, for example bunsik_sm1>
  FIXED_SMOKE_PASSWORD=<assigned password; never printed>
EOF
      exit 0
      ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

[[ "$ACCOUNT_CODE" =~ ^[a-z][a-z0-9_]{1,31}$ ]] ||
  fail "FIXED_SMOKE_ACCOUNT_CODE must be a valid fixed account code."
[[ -f "$PILOT_SMOKE_SCRIPT" ]] || fail "Missing generic POS login smoke script."
if [[ "$DRY_RUN" != "1" ]]; then
  [[ -n "${FIXED_SMOKE_PASSWORD:-}" ]] || fail "FIXED_SMOKE_PASSWORD is required."
fi

export PILOT_SMOKE_EMAIL="${ACCOUNT_CODE}@globos.world"
export PILOT_SMOKE_PASSWORD="${FIXED_SMOKE_PASSWORD:-dry-run-placeholder}"
export EXPECTED_FIXED_ACCOUNT_CODE="$ACCOUNT_CODE"

args=(--email "$PILOT_SMOKE_EMAIL" --expected-project-ref "$POS_PROJECT_REF")
[[ "$DRY_RUN" == "1" ]] && args+=(--dry-run)
exec bash "$PILOT_SMOKE_SCRIPT" "${args[@]}"
