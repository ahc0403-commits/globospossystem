#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"
EXPECTED_PROJECT_REF="${EXPECTED_PROJECT_REF:-ynriuoomotxuwhuxxmhj}"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.local}"
SMOKE_EMAIL="${PILOT_SMOKE_EMAIL:-}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  scripts/smoke_pilot_login.sh [options]

Logs in with one assigned POS pilot account against production Supabase Auth,
then verifies the authenticated POS public.users profile is readable. This
script never prints, creates, or resets passwords.

Required env for a real smoke:
  PILOT_SMOKE_EMAIL=dung.cashier01@globos.test
  PILOT_SMOKE_PASSWORD=<assigned password, never printed>

Options:
  --email EMAIL               Pilot email to test. Defaults to PILOT_SMOKE_EMAIL.
  --expected-project-ref REF  Expected linked Supabase project ref.
  --env-file FILE             Env file for SUPABASE_URL and SUPABASE_ANON_KEY.
  --dry-run                   Validate inputs and print what would be checked.
  -h, --help                  Show this help.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --email)
        shift
        SMOKE_EMAIL="${1:-}"
        [[ -n "$SMOKE_EMAIL" ]] || fail "--email requires a value"
        ;;
      --expected-project-ref)
        shift
        EXPECTED_PROJECT_REF="${1:-}"
        [[ -n "$EXPECTED_PROJECT_REF" ]] || fail "--expected-project-ref requires a value"
        ;;
      --env-file)
        shift
        ENV_FILE="${1:-}"
        [[ -n "$ENV_FILE" ]] || fail "--env-file requires a value"
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
    shift
  done
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    return 0
  fi

  if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$ROOT_DIR/.env"
    set +a
    return 0
  fi

  fail "Missing env file. Expected $ENV_FILE or $ROOT_DIR/.env"
}

verify_project_ref() {
  [[ -f "$PROJECT_REF_FILE" ]] || fail "Missing project ref file: $PROJECT_REF_FILE"
  local project_ref
  project_ref="$(tr -d '\r\n' < "$PROJECT_REF_FILE")"
  printf 'Supabase linked project: %s\n' "$project_ref"
  [[ "$project_ref" == "$EXPECTED_PROJECT_REF" ]] ||
    fail "Linked Supabase project is not production ($EXPECTED_PROJECT_REF)."
}

normalize_email() {
  SMOKE_EMAIL="$(printf '%s' "$SMOKE_EMAIL" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
  [[ -n "$SMOKE_EMAIL" ]] || fail "PILOT_SMOKE_EMAIL is required."
  [[ "$SMOKE_EMAIL" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+$ ]] ||
    fail "Invalid pilot smoke email: $SMOKE_EMAIL"
}

ensure_supabase_env() {
  load_env
  SMOKE_EMAIL="${SMOKE_EMAIL:-${PILOT_SMOKE_EMAIL:-}}"
  normalize_email

  [[ -n "${SUPABASE_URL:-}" ]] || fail "SUPABASE_URL is not set."
  [[ -n "${SUPABASE_ANON_KEY:-}" ]] || fail "SUPABASE_ANON_KEY is not set."

  local normalized_url
  local expected_url
  normalized_url="${SUPABASE_URL%/}"
  expected_url="https://$EXPECTED_PROJECT_REF.supabase.co"
  [[ "$normalized_url" == "$expected_url" ]] ||
    fail "SUPABASE_URL is not production $expected_url."
  SUPABASE_URL="$normalized_url"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'Pilot login smoke dry-run: %s against %s\n' "$SMOKE_EMAIL" "$SUPABASE_URL"
    return 0
  fi

  [[ -n "${PILOT_SMOKE_PASSWORD:-}" ]] ||
    fail "PILOT_SMOKE_PASSWORD is required for pilot login smoke."
}

json_login_payload() {
  EMAIL="$SMOKE_EMAIL" PASSWORD="$PILOT_SMOKE_PASSWORD" python3 - <<'PY'
import json
import os

print(json.dumps({
    "email": os.environ["EMAIL"],
    "password": os.environ["PASSWORD"],
}, separators=(",", ":")))
PY
}

read_json_message() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)

for key in ("error_description", "msg", "message", "error"):
    value = data.get(key)
    if value:
        print(str(value))
        break
PY
}

parse_login_response() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

access_token = data.get("access_token")
user = data.get("user") or {}
user_id = user.get("id")
email = (user.get("email") or "").lower()

if not access_token or not user_id:
    sys.exit("Supabase Auth response did not include an access token and user id.")

print(access_token)
print(user_id)
print(email)
PY
}

parse_profile_response() {
  python3 - "$1" "${EXPECTED_FIXED_ACCOUNT_CODE:-}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

if not isinstance(data, list) or len(data) != 1:
    sys.exit("Authenticated POS profile lookup did not return exactly one row.")

row = data[0]
if row.get("is_active") is False:
    sys.exit("Authenticated POS profile is inactive.")

expected_fixed_code = sys.argv[2]
if expected_fixed_code:
    if row.get("fixed_account_code") != expected_fixed_code:
        sys.exit("Authenticated POS profile fixed account code does not match.")
    if row.get("account_type") in (None, "", "legacy_user"):
        sys.exit("Authenticated POS profile is not a fixed account.")

print(str(row.get("role") or "unknown"))
print(str(row.get("restaurant_id") or "unknown"))
PY
}

smoke_login() {
  local login_response_file
  local profile_response_file
  login_response_file="$(mktemp)"
  profile_response_file="$(mktemp)"
  trap 'rm -f "${login_response_file:-}" "${profile_response_file:-}"' EXIT

  local login_status
  # Feed the password through stdin so it is not placed in curl arguments.
  login_status="$(json_login_payload | curl -sS \
    -o "$login_response_file" \
    -w '%{http_code}' \
    -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Content-Type: application/json" \
    --data-binary @-)"

  if [[ ! "$login_status" =~ ^2 ]]; then
    local login_message
    login_message="$(read_json_message "$login_response_file")"
    fail "Pilot login smoke failed for $SMOKE_EMAIL (HTTP $login_status: ${login_message:-Supabase Auth rejected the credentials})."
  fi

  local fields=()
  local line
  while IFS= read -r line; do
    fields+=("$line")
  done < <(parse_login_response "$login_response_file")

  local access_token="${fields[0]:-}"
  local auth_user_id="${fields[1]:-}"
  local auth_email="${fields[2]:-}"
  [[ "$auth_email" == "$SMOKE_EMAIL" ]] ||
    fail "Pilot login smoke returned unexpected auth email: ${auth_email:-unknown}"

  local profile_status
  profile_status="$(curl -sS \
    -o "$profile_response_file" \
    -w '%{http_code}' \
    "$SUPABASE_URL/rest/v1/users?select=role,restaurant_id,is_active,account_type,fixed_account_code&auth_id=eq.$auth_user_id&limit=1" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $access_token" \
    -H "Accept: application/json")"

  if [[ ! "$profile_status" =~ ^2 ]]; then
    local profile_message
    profile_message="$(read_json_message "$profile_response_file")"
    fail "Pilot POS profile smoke failed for $SMOKE_EMAIL (HTTP $profile_status: ${profile_message:-profile lookup rejected})."
  fi

  local profile_fields=()
  while IFS= read -r line; do
    profile_fields+=("$line")
  done < <(parse_profile_response "$profile_response_file")

  printf 'OK: Pilot login smoke passed: %s role=%s store=%s\n' \
    "$SMOKE_EMAIL" "${profile_fields[0]:-unknown}" "${profile_fields[1]:-unknown}"
}

main() {
  parse_args "$@"
  verify_project_ref
  ensure_supabase_env
  [[ "$DRY_RUN" == "1" ]] && return 0
  smoke_login
}

main "$@"
