#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"
EXPECTED_PROJECT_REF="${EXPECTED_PROJECT_REF:-ynriuoomotxuwhuxxmhj}"
ACCOUNTS_FILE="${PRODUCTION_AUTH_EMAILS_FILE:-${PILOT_AUTH_EMAILS_FILE:-$ROOT_DIR/docs/pos/pos_required_production_auth_emails.txt}}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  scripts/check_pilot_auth_accounts.sh [options]

Checks that required POS operational emails exist in production Supabase Auth,
have an active POS public.users profile linked by public.users.auth_id, and
carry loginable app_metadata.accessible_store_ids claims. It also blocks
active or unbanned .test identities and active test-marker stores. This check
never reads, prints, creates, or resets passwords.

Failure output is intentionally provisioning-oriented: Vercel cannot fix
missing Auth users or profile links.

Options:
  --file FILE                 Required email list. Defaults to docs/pos/pos_required_production_auth_emails.txt
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
  [[ -f "$ACCOUNTS_FILE" ]] || fail "Missing production Auth account file: $ACCOUNTS_FILE"

  local line
  local email
  REQUIRED_EMAILS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    email="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
    [[ -z "$email" ]] && continue
    [[ "$email" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+$ ]] ||
      fail "Invalid email in $ACCOUNTS_FILE: $email"
    [[ ! "$email" =~ \.test$ ]] ||
      fail "Reserved .test identities are forbidden in the production Auth requirement file: $email"
    REQUIRED_EMAILS+=("$email")
  done < "$ACCOUNTS_FILE"

  [[ "${#REQUIRED_EMAILS[@]}" -gt 0 ]] || fail "No required production Auth emails found."
}

verify_project_ref() {
  [[ -f "$PROJECT_REF_FILE" ]] || fail "Missing project ref file: $PROJECT_REF_FILE"
  local project_ref
  project_ref="$(tr -d '\r\n' < "$PROJECT_REF_FILE")"
  printf 'Supabase linked project: %s\n' "$project_ref"
  [[ "$project_ref" == "$EXPECTED_PROJECT_REF" ]] ||
    fail "Linked Supabase project is not production ($EXPECTED_PROJECT_REF)."
}

check_production_hygiene() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'Production test-data hygiene check dry-run: reserved .test identities and test-marker stores are forbidden.\n'
    return 0
  fi

  command -v supabase >/dev/null 2>&1 || fail "Missing required command: supabase"
  command -v python3 >/dev/null 2>&1 || fail "Missing required command: python3"

  local hygiene_query_file
  hygiene_query_file="$(mktemp)"
  cat >"$hygiene_query_file" <<'SQL'
with test_auth as (
  select id
  from auth.users
  where lower(coalesce(email, '')) ~ '@[^@]+\.test$'
),
test_profiles as (
  select u.id
  from public.users u
  join test_auth t on t.id = u.auth_id
)
select
  (select count(*) from auth.users au join test_auth t on t.id = au.id
    where au.banned_until is null or au.banned_until <= now()) as unbanned_test_auth,
  (select count(*) from public.users u join test_profiles t on t.id = u.id
    where u.is_active) as active_test_profiles,
  (select count(*) from public.user_store_access usa join test_profiles t on t.id = usa.user_id
    where usa.is_active) as active_test_store_access,
  (select count(*) from public.user_brand_access uba join test_profiles t on t.id = uba.user_id
    where uba.is_active) as active_test_brand_access,
  (select count(*) from public.restaurants r
    left join public.brands b on b.id = r.brand_id
    where r.is_active and (
      lower(r.name) ~ '(test|fixture|smoke|pilot)'
      or upper(coalesce(b.code, '')) like 'SMK_%'
    )) as active_test_marker_stores,
  (select count(*) from public.user_store_access usa
    join public.restaurants r on r.id = usa.store_id
    where usa.is_active and r.is_active = false) as active_access_to_inactive_store;
SQL

  local query_output
  if ! query_output="$(supabase db query --linked -f "$hygiene_query_file" -o json)"; then
    rm -f "$hygiene_query_file"
    fail "Could not verify production test-data hygiene."
  fi
  rm -f "$hygiene_query_file"

  local counts
  counts="$(HYGIENE_QUERY_JSON="$query_output" python3 - <<'PY'
import json
import os

raw = os.environ["HYGIENE_QUERY_JSON"]
start = raw.find("{")
end = raw.rfind("}")
if start < 0 or end < start:
    raise SystemExit("Supabase CLI did not return hygiene JSON.")
data = json.loads(raw[start : end + 1])
rows = data.get("rows", data)
if not isinstance(rows, list) or len(rows) != 1:
    raise SystemExit("Production hygiene query did not return exactly one row.")
row = rows[0]
keys = (
    "unbanned_test_auth",
    "active_test_profiles",
    "active_test_store_access",
    "active_test_brand_access",
    "active_test_marker_stores",
    "active_access_to_inactive_store",
)
print("\t".join(str(row.get(key, 0)) for key in keys))
PY
)"

  local unbanned_test_auth
  local active_test_profiles
  local active_test_store_access
  local active_test_brand_access
  local active_test_marker_stores
  local active_access_to_inactive_store
  IFS=$'\t' read -r \
    unbanned_test_auth \
    active_test_profiles \
    active_test_store_access \
    active_test_brand_access \
    active_test_marker_stores \
    active_access_to_inactive_store <<<"$counts"

  if [[ "$unbanned_test_auth" != "0" \
     || "$active_test_profiles" != "0" \
     || "$active_test_store_access" != "0" \
     || "$active_test_brand_access" != "0" \
     || "$active_test_marker_stores" != "0" \
     || "$active_access_to_inactive_store" != "0" ]]; then
    printf 'BLOCKER: Production test-data hygiene violation: unbanned_test_auth=%s active_test_profiles=%s active_test_store_access=%s active_test_brand_access=%s active_test_marker_stores=%s active_access_to_inactive_store=%s\n' \
      "$unbanned_test_auth" \
      "$active_test_profiles" \
      "$active_test_store_access" \
      "$active_test_brand_access" \
      "$active_test_marker_stores" \
      "$active_access_to_inactive_store" >&2
    fail "Production contains active test or invalid store-scope artifacts. Deployment is blocked."
  fi

  printf 'Production test-data hygiene: OK\n'
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
    au.raw_app_meta_data,
    pu.id as pos_user_id,
    pu.role,
    pu.restaurant_id,
    pu.is_active
  from required r
  left join auth.users au
    on lower(au.email) = r.email
  left join public.users pu
    on pu.auth_id = au.id
),
scope as (
  select
    m.email,
    count(scope_id.store_id) as accessible_store_count,
    count(rs.id) as valid_store_count
  from matched m
  left join lateral jsonb_array_elements_text(
    case
      when jsonb_typeof(m.raw_app_meta_data->'accessible_store_ids') = 'array'
        then m.raw_app_meta_data->'accessible_store_ids'
      else '[]'::jsonb
    end
  ) as scope_id(store_id) on true
  left join public.restaurants rs
    on rs.id::text = scope_id.store_id
  group by m.email
)
select
  m.email,
  case
    when m.auth_user_id is null then 'MISSING_AUTH'
    when m.email_confirmed_at is null then 'UNCONFIRMED_AUTH'
    when m.pos_user_id is null then 'MISSING_POS_PROFILE'
    when m.is_active is distinct from true then 'INACTIVE_POS_PROFILE'
    when coalesce(m.role::text, '') not in (
      'super_admin', 'brand_admin', 'store_admin', 'admin',
      'waiter', 'kitchen', 'cashier',
      'photo_objet_master', 'photo_objet_store_admin',
      'photo_objet_store_operator'
    ) then 'UNKNOWN_ROLE'
    when coalesce(s.accessible_store_count, 0) = 0 then 'MISSING_STORE_SCOPE'
    when coalesce(s.valid_store_count, 0) <> coalesce(s.accessible_store_count, 0)
      then 'INVALID_STORE_SCOPE'
    else 'OK'
  end as status,
  coalesce(m.role::text, '') as role,
  coalesce(m.restaurant_id::text, '') as restaurant_id,
  coalesce(s.accessible_store_count, 0)::text as accessible_store_count,
  coalesce(s.valid_store_count, 0)::text as valid_store_count
from matched m
left join scope s
  on s.email = m.email
order by m.email;
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
    print("\t".join(str(row.get(key) or "") for key in (
        "email",
        "status",
        "role",
        "restaurant_id",
        "accessible_store_count",
        "valid_store_count",
    )))
PY
}

print_blocker_report() {
  local missing_auth="$1"
  local unconfirmed_auth="$2"
  local missing_profile="$3"
  local inactive_profile="$4"
  local unknown_role="$5"
  local missing_scope="$6"
  local invalid_scope="$7"

  printf '\nROOT_CAUSE: Required POS operational identity state is missing from production Supabase, not from the Vercel frontend.\n' >&2
  printf 'PROJECT: %s\n' "$EXPECTED_PROJECT_REF" >&2
  printf 'SOURCE: %s\n' "$ACCOUNTS_FILE" >&2
  printf 'APP_PROFILE_LOOKUP: auth.users.email -> auth.users.id -> public.users.auth_id\n' >&2

  if [[ -n "$missing_auth" ]]; then
    printf 'NEXT_ACTION MISSING_AUTH: provision only the approved production operational identity, confirm email, then link/create public.users.auth_id.\n' >&2
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

  if [[ -n "$inactive_profile" ]]; then
    printf 'NEXT_ACTION INACTIVE_POS_PROFILE: confirm the approved operational assignment before reactivating the POS profile or updating the required list.\n' >&2
    printf '%s\n' "$inactive_profile" | while IFS= read -r email; do
      [[ -n "$email" ]] && printf '  - %s\n' "$email" >&2
    done
  fi

  if [[ -n "$unknown_role" ]]; then
    printf 'NEXT_ACTION UNKNOWN_ROLE: set public.users.role to a supported POS role before deploying.\n' >&2
    printf '%s\n' "$unknown_role" | while IFS= read -r email; do
      [[ -n "$email" ]] && printf '  - %s\n' "$email" >&2
    done
  fi

  if [[ -n "$missing_scope" ]]; then
    printf 'NEXT_ACTION MISSING_STORE_SCOPE: run refresh_user_claims after repairing user_store_access; accessible_store_ids empty.\n' >&2
    printf '%s\n' "$missing_scope" | while IFS= read -r email; do
      [[ -n "$email" ]] && printf '  - %s\n' "$email" >&2
    done
  fi

  if [[ -n "$invalid_scope" ]]; then
    printf 'NEXT_ACTION INVALID_STORE_SCOPE: remove stale accessible_store_ids or repair the referenced restaurants rows.\n' >&2
    printf '%s\n' "$invalid_scope" | while IFS= read -r email; do
      [[ -n "$email" ]] && printf '  - %s\n' "$email" >&2
    done
  fi

  printf 'RUNBOOK: docs/pos/POS_PRODUCTION_AUTH_OPERATIONS_RUNBOOK.md\n' >&2
  printf 'SAFETY: .test identities are forbidden; do not print, store, reset, or rotate production passwords in deployment automation.\n\n' >&2
}

check_accounts() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'Production Auth account check dry-run: %s accounts from %s\n' \
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
  local inactive_profile=""
  local unknown_role=""
  local missing_scope=""
  local invalid_scope=""
  local email
  local status
  local role
  local restaurant_id
  local accessible_store_count
  local valid_store_count
  while IFS=$'\t' read -r email status role restaurant_id accessible_store_count valid_store_count; do
    [[ -z "$email" ]] && continue
    if [[ "$status" == "OK" ]]; then
      printf 'OK: %s role=%s store=%s scope=%s/%s\n' "$email" "${role:-unknown}" "${restaurant_id:-unknown}" "${valid_store_count:-0}" "${accessible_store_count:-0}"
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
        INACTIVE_POS_PROFILE)
          inactive_profile="${inactive_profile}${email}"$'\n'
          ;;
        UNKNOWN_ROLE)
          unknown_role="${unknown_role}${email}"$'\n'
          ;;
        MISSING_STORE_SCOPE)
          missing_scope="${missing_scope}${email}"$'\n'
          ;;
        INVALID_STORE_SCOPE)
          invalid_scope="${invalid_scope}${email}"$'\n'
          ;;
      esac
      has_failure=1
    fi
  done <<< "$rows_tsv"

  if [[ "$has_failure" != "0" ]]; then
    print_blocker_report "$missing_auth" "$unconfirmed_auth" "$missing_profile" "$inactive_profile" "$unknown_role" "$missing_scope" "$invalid_scope"
    fail "Required POS production Auth accounts are not ready. Fix the approved operational accounts before deploying."
  fi
}

main() {
  parse_args "$@"
  read_required_emails
  verify_project_ref
  check_production_hygiene
  check_accounts
}

main "$@"
