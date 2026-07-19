#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly POS_PROJECT_REF="ynriuoomotxuwhuxxmhj"
readonly POS_PROJECT_URL="https://${POS_PROJECT_REF}.supabase.co"
readonly REQUIRED_CONFIRMATION="RESET_GLOBOS_PROD_OPERATIONAL_PASSWORDS"
ENV_FILE="${ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/globos/pos-production.env}"
ACCOUNTS_FILE="${POS_OPERATIONAL_ACCOUNTS_FILE:-$ROOT_DIR/docs/pos/pos_required_production_auth_emails.txt}"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  unset POS_INITIAL_PASSWORD POS_SUPABASE_SERVICE_ROLE_KEY api_keys_json
}
trap cleanup EXIT

[[ "${CONFIRM_PRODUCTION_PASSWORD_RESET:-}" == "$REQUIRED_CONFIRMATION" ]] ||
  fail "Explicit production password reset confirmation is required."
[[ -f "$ENV_FILE" ]] || fail "Secure POS production env is missing."
env_mode="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE")"
[[ "$env_mode" == "600" ]] || fail "Secure POS production env must have mode 600."

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

[[ "${SUPABASE_URL:-}" == "$POS_PROJECT_URL" ]] || fail "SUPABASE_URL is not POS production."
[[ -n "${SUPABASE_ANON_KEY:-}" ]] || fail "SUPABASE_ANON_KEY is missing."
[[ -n "${SUPABASE_ACCESS_TOKEN:-}" ]] || fail "SUPABASE_ACCESS_TOKEN is missing."
[[ -f "$ROOT_DIR/supabase/.temp/project-ref" ]] || fail "Linked project ref is missing."
[[ "$(tr -d '\r\n' < "$ROOT_DIR/supabase/.temp/project-ref")" == "$POS_PROJECT_REF" ]] ||
  fail "Linked Supabase project is not POS production."

command -v git >/dev/null 2>&1 || fail "git is required."
command -v deno >/dev/null 2>&1 || fail "deno is required."
command -v python3 >/dev/null 2>&1 || fail "python3 is required."
command -v supabase >/dev/null 2>&1 || fail "supabase is required."
[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] ||
  fail "Refusing production password reset from a dirty worktree."
git -C "$ROOT_DIR" fetch --quiet origin +refs/heads/main:refs/remotes/origin/main
[[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$(git -C "$ROOT_DIR" rev-parse origin/main)" ]] ||
  fail "Production password reset requires exact HEAD == freshly fetched origin/main."

[[ -f "$ACCOUNTS_FILE" ]] || fail "Approved operational account list is missing."
bash "$ROOT_DIR/scripts/check_pilot_auth_accounts.sh" --file "$ACCOUNTS_FILE"

if [[ -z "${POS_INITIAL_PASSWORD:-}" ]]; then
  [[ -t 0 ]] || fail "Run interactively so the password can be entered without echo."
  IFS= read -r -s -p "Initial password for approved operational accounts: " POS_INITIAL_PASSWORD
  printf '\n'
fi
[[ "${#POS_INITIAL_PASSWORD}" -ge 8 ]] || fail "Initial password must be at least 8 characters."

api_keys_json="$(
  supabase projects api-keys --project-ref "$POS_PROJECT_REF" -o json
)"
POS_SUPABASE_SERVICE_ROLE_KEY="$(
  API_KEYS_JSON="$api_keys_json" python3 - <<'PY'
import json
import os
import sys

keys = json.loads(os.environ.get("API_KEYS_JSON", "[]"))
matches = [
    item for item in keys
    if item.get("id") == "service_role" and isinstance(item.get("api_key"), str)
]
if len(matches) != 1:
    raise SystemExit(1)
sys.stdout.write(matches[0]["api_key"])
PY
)" || fail "Could not load the POS production service role key."
[[ -n "$POS_SUPABASE_SERVICE_ROLE_KEY" ]] || fail "POS production service role key is empty."
unset api_keys_json

POS_SUPABASE_URL="$SUPABASE_URL" \
POS_SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
POS_SUPABASE_SERVICE_ROLE_KEY="$POS_SUPABASE_SERVICE_ROLE_KEY" \
POS_INITIAL_PASSWORD="$POS_INITIAL_PASSWORD" \
POS_EXPECTED_CREATED_DATE_VN="${POS_EXPECTED_CREATED_DATE_VN:-}" \
POS_OPERATIONAL_ACCOUNTS_FILE="$ACCOUNTS_FILE" \
CONFIRM_PRODUCTION_PASSWORD_RESET="$CONFIRM_PRODUCTION_PASSWORD_RESET" \
  deno run \
    --allow-env=POS_SUPABASE_URL,POS_SUPABASE_ANON_KEY,POS_SUPABASE_SERVICE_ROLE_KEY,POS_INITIAL_PASSWORD,POS_EXPECTED_CREATED_DATE_VN,POS_OPERATIONAL_ACCOUNTS_FILE,CONFIRM_PRODUCTION_PASSWORD_RESET \
    --allow-read="$ACCOUNTS_FILE" \
    --allow-net="$POS_PROJECT_REF.supabase.co" \
    "$ROOT_DIR/scripts/reset_production_operational_passwords.mjs"
