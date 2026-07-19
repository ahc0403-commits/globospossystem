#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly POS_PROJECT_REF="ynriuoomotxuwhuxxmhj"
readonly POS_PROJECT_URL="https://${POS_PROJECT_REF}.supabase.co"
readonly REQUIRED_CONFIRMATION="RESET_GLOBOS_PROD_OPERATIONAL_PASSWORDS"
ENV_FILE="${ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/globos/pos-production.env}"
ACCOUNTS_FILE="${POS_OPERATIONAL_ACCOUNTS_FILE:-$ROOT_DIR/docs/pos/pos_required_production_auth_emails.txt}"
PREFLIGHT_ONLY=0

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  unset POS_INITIAL_PASSWORD
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight-only) PREFLIGHT_ONLY=1 ;;
    -h|--help)
      printf 'Usage: %s [--preflight-only]\n' "$0"
      exit 0
      ;;
    *) fail "Unknown option: $1" ;;
  esac
  shift
done

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
command -v node >/dev/null 2>&1 || fail "node is required."
command -v npm >/dev/null 2>&1 || fail "npm is required."
command -v supabase >/dev/null 2>&1 || fail "supabase is required."
[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] ||
  fail "Refusing production password reset from a dirty worktree."
git -C "$ROOT_DIR" fetch --quiet origin +refs/heads/main:refs/remotes/origin/main
[[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$(git -C "$ROOT_DIR" rev-parse origin/main)" ]] ||
  fail "Production password reset requires exact HEAD == freshly fetched origin/main."

[[ -f "$ACCOUNTS_FILE" ]] || fail "Approved operational account list is missing."
bash "$ROOT_DIR/scripts/check_pilot_auth_accounts.sh" --file "$ACCOUNTS_FILE"
npm --prefix "$ROOT_DIR/scripts" ci --ignore-scripts --no-audit --no-fund

if [[ "$PREFLIGHT_ONLY" == "1" ]]; then
  POS_INITIAL_PASSWORD="preflight-only-placeholder"
elif [[ -z "${POS_INITIAL_PASSWORD:-}" ]]; then
  [[ -t 0 ]] || fail "Run interactively so the password can be entered without echo."
  IFS= read -r -s -p "Initial password for approved operational accounts: " POS_INITIAL_PASSWORD
  printf '\n'
fi
[[ "${#POS_INITIAL_PASSWORD}" -ge 8 ]] || fail "Initial password must be at least 8 characters."

ENV_FILE="$ENV_FILE" \
POS_SUPABASE_URL="$SUPABASE_URL" \
POS_SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
POS_INITIAL_PASSWORD="$POS_INITIAL_PASSWORD" \
POS_EXPECTED_CREATED_DATE_VN="${POS_EXPECTED_CREATED_DATE_VN:-}" \
POS_OPERATIONAL_ACCOUNTS_FILE="$ACCOUNTS_FILE" \
POS_PREFLIGHT_ONLY="$PREFLIGHT_ONLY" \
CONFIRM_PRODUCTION_PASSWORD_RESET="$CONFIRM_PRODUCTION_PASSWORD_RESET" \
  bash -c '
    set -euo pipefail
    source "$1"
    DB_ONLY=1
    acquire_linked_pg_credentials
    trap '\''unset PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE POS_INITIAL_PASSWORD'\'' EXIT
    PGHOST="$PGHOST" \
    PGPORT="$PGPORT" \
    PGUSER="$PGUSER" \
    PGPASSWORD="$PGPASSWORD" \
    PGDATABASE="$PGDATABASE" \
      node "$2"
  ' bash \
    "$ROOT_DIR/scripts/deploy_pos_production.sh" \
    "$ROOT_DIR/scripts/reset_production_operational_passwords_db.mjs"
