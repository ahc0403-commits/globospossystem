#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"
EXPECTED_PROJECT_REF="${EXPECTED_PROJECT_REF:-ynriuoomotxuwhuxxmhj}"
ACCOUNTS_FILE="${PILOT_AUTH_EMAILS_FILE:-$ROOT_DIR/docs/manual_test/pos_required_pilot_auth_emails.txt}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  scripts/check_pilot_auth_accounts.sh [options]

Checks that required POS pilot emails exist in production Supabase Auth and
have a POS public.users profile linked by public.users.auth_id. This check
never reads, prints, creates, or resets passwords.

Failure output is intentionally provisioning-oriented: Vercel cannot fix
missing Auth users or profile links.

Options:
  --file FILE                 Required email list. Defaults to docs/manual_test/pos_required_pilot_auth_emails.txt
  --expected-project-ref REF  Expected linked Supabase project ref.
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
      --file)
        shift
        ACCOUNTS_FILE="${1:-}"
        [[ -n "$ACCOUNTS_FILE" ]] || fail "--file requires a value"
        ;;
      --expected-project-ref)
        shift
        EXPECTED_PROJECT_REF="${1:-}"
        [[ -n "$EXPECTED_PROJECT_REF" ]] || fail "--expected-project-ref requires a value"
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

read_required_emails() {
  [[ -f "$ACCOUNTS_FILE" ]] || fail "Missing pilot Auth account file: $ACCOUNTS_FILE"

  local line
  local email
  REQUIRED_EMAILS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    email="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
    [[ -z "$email" ]] && continue
    [[ "$email" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+$ ]] ||
      fail "Invalid email in $ACCOUNTS_FILE: $email"
    REQUIRED_EMAILS+=("$email")
  done < "$ACCOUNTS_FILE"

  [[ "${#REQUIRED_EMAILS[@]}" -gt 0 ]] || fail "No required pilot Auth emails found."
}

verify_project_ref() {
  [[ -f "$PROJECT_REF_FILE" ]] || fail "Missing project ref file: $PROJECT_REF_FILE"
  local project_ref
  project_ref="$(tr -d '\r\n' < "$PROJECT_REF_FILE")"
  printf 'Supabase linked project: %s\n' "$project_ref"
  [[ "$project_ref" == "$EXPECTED_PROJECT_REF" ]] ||
    fail "Linked Supabase project is not production ($EXPECTED_PROJECT_REF)."
}

build_query_file() {
  QUERY_FILE="$(mktemp)"
  {
    printf 'with required(email) as (\n  values\n'
    local index=0
    local last_index=$((${#REQUIRED_EMAILS[@]} - 1))
    local email
    for email in "${REQUIRED_EMAILS[@]}"; do
      if [[ "$index" -lt "$last_index" ]]; then
        printf "    ('%s'),\n" "$email"
      else
        printf "    ('%s')\n" "$email"
      fi
      index=$((index + 1))
    done
    cat <<'SQL'
),
matched as (
  select
    r.email,
    au.id as auth_user_id,
    au.email_confirmed_at,
    pu.id as pos_user_id,
    pu.role,
    pu.restaurant_id
  from required r
  left join auth.users au
    on lower(au.email) = r.email
  left join public.users pu
    on pu.auth_id = au.id
)
select
  email,
  case
    when auth_user_id is null then 'MISSING_AUTH'
    when email_confirmed_at is null then 'UNCONFIRMED_AUTH'
    when pos_user_id is null then 'MISSING_POS_PROFILE'
    else 'OK'
  end as status,
  coalesce(role::text, '') as role,
  coalesce(restaurant_id::text, '') as restaurant_id
from matched
order by email;
SQL
  } > "$QUERY_FILE"
}

parse_rows() {
  QUERY_JSON="$1" python3 - <<'PY'
import json
import os
import sys

raw = os.environ["QUERY_JSON"]
start = raw.find("{")
end = raw.rfind("}")
if start < 0 or end < start:
    sys.exit("Supabase CLI did not return JSON.")

data = json.loads(raw[start : end + 1])
rows = data.get("rows", data)
if not isinstance(rows, list):
    sys.exit("Supabase CLI JSON did not contain a rows list.")

for row in rows:
    print("\t".join(str(row.get(key) or "") for key in ("email", "status", "role", "restaurant_id")))
PY
}

print_blocker_report() {
  local missing_auth="$1"
  local unconfirmed_auth="$2"
  local missing_profile="$3"

  printf '\nROOT_CAUSE: Required POS pilot identity state is missing from production Supabase, not from the Vercel frontend.\n' >&2
  printf 'PROJECT: %s\n' "$EXPECTED_PROJECT_REF" >&2
  printf 'SOURCE: %s\n' "$ACCOUNTS_FILE" >&2
  printf 'APP_PROFILE_LOOKUP: auth.users.email -> auth.users.id -> public.users.auth_id\n' >&2

  if [[ -n "$missing_auth" ]]; then
    printf 'NEXT_ACTION MISSING_AUTH: create the production Supabase Auth user with the assigned pilot credential, confirm email, then link/create public.users.auth_id.\n' >&2
    printf '%s\n' "$missing_auth" | while IFS= read -r email; do
      [[ -n "$email" ]] && printf '  - %s\n' "$email" >&2
    done
  fi

  if [[ -n "$unconfirmed_auth" ]]; then
    printf 'NEXT_ACTION UNCONFIRMED_AUTH: confirm the existing production Supabase Auth user before deploying.\n' >&2
    printf '%s\n' "$unconfirmed_auth" | while IFS= read -r email; do
      [[ -n "$email" ]] && printf '  - %s\n' "$email" >&2
    done
  fi

  if [[ -n "$missing_profile" ]]; then
    printf 'NEXT_ACTION MISSING_POS_PROFILE: create or repair the POS public.users row linked by auth_id.\n' >&2
    printf '%s\n' "$missing_profile" | while IFS= read -r email; do
      [[ -n "$email" ]] && printf '  - %s\n' "$email" >&2
    done
  fi

  printf 'RUNBOOK: docs/manual_test/pos_pilot_auth_provisioning_runbook.md\n' >&2
  printf 'SAFETY: do not print, store, reset, or rotate pilot passwords in deployment automation.\n\n' >&2
}

check_accounts() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'Pilot Auth account check dry-run: %s accounts from %s\n' \
      "${#REQUIRED_EMAILS[@]}" "$ACCOUNTS_FILE"
    return 0
  fi

  command -v supabase >/dev/null 2>&1 || fail "Missing required command: supabase"
  build_query_file
  trap 'rm -f "${QUERY_FILE:-}"' EXIT

  local query_output
  query_output="$(supabase db query --linked -f "$QUERY_FILE" -o json)"

  local rows_tsv
  rows_tsv="$(parse_rows "$query_output")"

  local has_failure=0
  local missing_auth=""
  local unconfirmed_auth=""
  local missing_profile=""
  local email
  local status
  local role
  local restaurant_id
  while IFS=$'\t' read -r email status role restaurant_id; do
    [[ -z "$email" ]] && continue
    if [[ "$status" == "OK" ]]; then
      printf 'OK: %s role=%s store=%s\n' "$email" "${role:-unknown}" "${restaurant_id:-unknown}"
    else
      printf 'BLOCKER: %s %s\n' "$email" "$status" >&2
      case "$status" in
        MISSING_AUTH)
          missing_auth="${missing_auth}${email}"$'\n'
          ;;
        UNCONFIRMED_AUTH)
          unconfirmed_auth="${unconfirmed_auth}${email}"$'\n'
          ;;
        MISSING_POS_PROFILE)
          missing_profile="${missing_profile}${email}"$'\n'
          ;;
      esac
      has_failure=1
    fi
  done <<< "$rows_tsv"

  if [[ "$has_failure" != "0" ]]; then
    print_blocker_report "$missing_auth" "$unconfirmed_auth" "$missing_profile"
    fail "Required POS pilot Auth accounts are not ready. Fix accounts in Supabase Auth before deploying."
  fi
}

main() {
  parse_args "$@"
  read_required_emails
  verify_project_ref
  check_accounts
}

main "$@"
