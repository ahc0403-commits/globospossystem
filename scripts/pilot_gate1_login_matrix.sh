#!/usr/bin/env bash
set -euo pipefail

# pilot_gate1_login_matrix.sh
# Gate 1 (Test Plan 2026-07-03): login matrix over the 5 pilot role accounts.
# Per account, asserts (login gate contract AC2/AC6):
#   1. password login succeeds against Supabase Auth
#   2. JWT app_metadata role source (public.users.role) matches expected role
#   3. app_metadata.accessible_store_ids is a non-empty array
#      (super_admin is exempt — AC6; empty scope for others = FAIL, C3)
# Never prints passwords. Modeled on scripts/smoke_pilot_login.sh conventions.
#
# Required env:
#   PILOT_SMOKE_PASSWORD   shared pilot password
#   SUPABASE_URL, SUPABASE_ANON_KEY (or provide --env-file, default .env.local)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.local}"
DRY_RUN=0

ACCOUNTS=(
  "superadmin@globos.test:super_admin"
  "admin@globos.test:admin"
  "waiter@globos.test:waiter"
  "kitchen@globos.test:kitchen"
  "cashier@globos.test:cashier"
)

usage() {
  cat <<'EOF'
Usage:
  scripts/pilot_gate1_login_matrix.sh [--env-file FILE] [--dry-run]

Verifies the 5 pilot role accounts can log in and carry a non-empty
accessible_store_ids claim. Exits non-zero if any row fails.
EOF
}

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) shift; ENV_FILE="${1:-}"; [[ -n "$ENV_FILE" ]] || fail "--env-file requires a value" ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "DRY RUN — would check the following accounts against ${SUPABASE_URL:-<unset SUPABASE_URL>}:"
  for entry in "${ACCOUNTS[@]}"; do
    echo "  ${entry%%:*} (expect role=${entry##*:})"
  done
  exit 0
fi

[[ -n "${SUPABASE_URL:-}" ]] || fail "SUPABASE_URL not set (env or --env-file)"
[[ -n "${SUPABASE_ANON_KEY:-}" ]] || fail "SUPABASE_ANON_KEY not set (env or --env-file)"
[[ -n "${PILOT_SMOKE_PASSWORD:-}" ]] || fail "PILOT_SMOKE_PASSWORD not set"
[[ "${SUPABASE_URL%/}" != "https://ynriuoomotxuwhuxxmhj.supabase.co" ]] ||
  fail "Test-account login matrix is forbidden against POS production."
command -v python3 >/dev/null || fail "python3 required"
command -v curl >/dev/null || fail "curl required"

PASS_COUNT=0
FAIL_COUNT=0

check_account() {
  local email="$1" expected_role="$2"
  local response
  response="$(curl -s -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Content-Type: application/json" \
    --data "{\"email\":\"$email\",\"password\":$(python3 -c 'import json,os;print(json.dumps(os.environ["PILOT_SMOKE_PASSWORD"]))')}")"

  # Evaluate: login ok, role matches, store scope non-empty (super_admin exempt).
  local verdict status=0
  verdict="$(RESPONSE="$response" EXPECTED_ROLE="$expected_role" EMAIL="$email" \
             SUPABASE_URL="$SUPABASE_URL" SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" python3 <<'PYEOF'
import json, os, sys, urllib.request

resp = json.loads(os.environ["RESPONSE"])
email = os.environ["EMAIL"]
expected_role = os.environ["EXPECTED_ROLE"]

if "access_token" not in resp:
    print(f"FAIL {email}: login refused — {resp.get('error_description') or resp.get('msg') or resp.get('error') or 'unknown'}")
    sys.exit(1)

token = resp["access_token"]
app_meta = (resp.get("user") or {}).get("app_metadata") or {}
store_ids = app_meta.get("accessible_store_ids")

# Resolve role from public.users via authenticated REST (same lookup the app does)
req = urllib.request.Request(
    os.environ["SUPABASE_URL"] + "/rest/v1/users?select=role,is_active&auth_id=eq." + resp["user"]["id"],
    headers={
        "apikey": os.environ["SUPABASE_ANON_KEY"],
        "Authorization": "Bearer " + token,
    },
)
rows = json.loads(urllib.request.urlopen(req, timeout=20).read().decode())

failures = []
if len(rows) != 1:
    failures.append(f"profile rows={len(rows)} (expected 1)")
else:
    if rows[0].get("role") != expected_role:
        failures.append(f"role={rows[0].get('role')} (expected {expected_role})")
    if rows[0].get("is_active") is not True:
        failures.append("is_active=false")

if expected_role != "super_admin":
    if not isinstance(store_ids, list) or len(store_ids) == 0:
        failures.append("accessible_store_ids EMPTY (C3 — storeId would be null)")

if failures:
    print(f"FAIL {email}: " + "; ".join(failures))
    sys.exit(1)

scope = f"{len(store_ids)} store(s)" if isinstance(store_ids, list) else "exempt"
print(f"PASS {email}: role={expected_role}, scope={scope}")
PYEOF
)" || status=1
  echo "$verdict"
  return $status
}

echo "Gate 1 — pilot login matrix against $SUPABASE_URL"
for entry in "${ACCOUNTS[@]}"; do
  email="${entry%%:*}"
  expected_role="${entry##*:}"
  if check_account "$email" "$expected_role"; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

echo "----"
echo "Gate 1 result: $PASS_COUNT PASS / $FAIL_COUNT FAIL"
if [[ $FAIL_COUNT -gt 0 ]]; then
  echo "Gate 1 FAILED — do not proceed to Gate 2 (see PILOT_SMOKE_GATE_TEST_PLAN_2026_07_03.md)"
  exit 1
fi
echo "Gate 1 PASSED"
