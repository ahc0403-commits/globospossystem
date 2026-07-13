#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"

readonly POS_PROJECT_REF="ynriuoomotxuwhuxxmhj"
readonly POS_PSQL_ROLE="postgres"
readonly POS_VERCEL_PROJECT="globospossystem"
readonly POS_VERCEL_PROJECT_ID="prj_glOhZuHqHUHyAsGaSx5BVip3MIJJ"
readonly POS_VERCEL_ORG_ID="team_4AfACJKDlP09zRqoJKce3Tib"
readonly LIVE_URL="https://globospossystem.vercel.app"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.local}"
MIGRATION_FILE="${MIGRATION_FILE:-}"
TEST_TARGETS="${TEST_TARGETS:-test/pilot_feedback_closure_contract_test.dart}"
DEPLOY_MODE="${DEPLOY_MODE:-prebuilt}"
PILOT_AUTH_EMAILS_FILE="${PILOT_AUTH_EMAILS_FILE:-$ROOT_DIR/docs/manual_test/pos_required_pilot_auth_emails.txt}"
PILOT_LOGIN_SMOKE_SCRIPT="${PILOT_LOGIN_SMOKE_SCRIPT:-$ROOT_DIR/scripts/smoke_pilot_login.sh}"

YES="${YES:-0}"
DRY_RUN=0
SKIP_CHECKS="${SKIP_CHECKS:-0}"
SKIP_AUTH_CHECK="${SKIP_AUTH_CHECK:-0}"
SKIP_LOGIN_SMOKE="${SKIP_LOGIN_SMOKE:-0}"
SKIP_DB="${SKIP_DB:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_VERCEL="${SKIP_VERCEL:-0}"
REQUIRE_CLEAN_GIT="${REQUIRE_CLEAN_GIT:-1}"
ROLLBACK_HIERARCHY=0

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy_pos_production.sh [options]

Default flow:
  preflight -> pilot Auth readiness -> locked Flutter dependency bootstrap ->
  dart analyze -> focused tests ->
  optional DB migration -> vercel build --prod ->
  vercel deploy --prebuilt --prod -> live HTTP check -> pilot login smoke

Options:
  --migration FILE   Apply one Supabase migration before deploying.
  --mode MODE        prebuilt (default) or remote.
  --test FILE        Add a flutter test target. Use "all" for flutter test.
  --no-tests         Skip flutter test targets while keeping dart analyze.
  --skip-checks      Skip dart analyze and flutter tests.
  --skip-auth-check  Skip required production pilot Auth account readiness check.
  --skip-login-smoke Skip post-deploy pilot login smoke. Report as blocker-risk.
  --skip-db          Skip Supabase migration work.
  --skip-build       In remote mode, skip the local flutter build precheck.
  --skip-vercel      Skip Vercel deployment.
  --rollback-hierarchy
                     Destructively roll back migration 20260711090000 only.
                     Requires CONFIRM_HIERARCHY_ROLLBACK=ROLLBACK_HIERARCHY_20260711090000.
  --dry-run          Print the deployment path without changing anything.
  --yes             Do not prompt for the production confirmation phrase.
  -h, --help         Show this help.

Useful env:
  CONFIRM_PRODUCTION_DEPLOY=DEPLOY_GLOBOS_PROD
  MIGRATION_FILE=supabase/migrations/20260616000000_pos_pilot_feedback_closure.sql
  DEPLOY_MODE=remote
  TEST_TARGETS="test/a.dart test/b.dart"
  PILOT_AUTH_EMAILS_FILE=docs/manual_test/pos_required_pilot_auth_emails.txt
  PILOT_SMOKE_EMAIL=dung.cashier01@globos.test
  PILOT_SMOKE_PASSWORD=<set securely in environment; never print it>
  REQUIRE_CLEAN_GIT=0 (accepted only with --dry-run)
EOF
}

log() {
  printf '\n==> %s\n' "$1"
}

warn() {
  printf 'WARN: %s\n' "$1" >&2
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

reject_target_overrides() {
  local variable
  for variable in \
    SUPABASE_DB_URL \
    EXPECTED_PROJECT_REF \
    ALLOW_PROJECT_REF_MISMATCH \
    EXPECTED_VERCEL_PROJECT \
    VERCEL_PROJECT_ID \
    VERCEL_ORG_ID; do
    [[ -z "${!variable:-}" ]] ||
      fail "$variable is forbidden; POS production targets are hard-pinned."
  done

  local candidate
  for candidate in "$ENV_FILE" "$ROOT_DIR/.env"; do
    if [[ -f "$candidate" ]] && grep -Eq \
      '^[[:space:]]*(export[[:space:]]+)?(SUPABASE_DB_URL|EXPECTED_PROJECT_REF|ALLOW_PROJECT_REF_MISMATCH|EXPECTED_VERCEL_PROJECT|VERCEL_PROJECT_ID|VERCEL_ORG_ID)=' \
      "$candidate"; then
      fail "Forbidden production target override found in $candidate."
    fi
  done
}

production_deploy_path_requested() {
  [[ "$SKIP_VERCEL" != "1" ]] && return 0
  [[ "$SKIP_DB" != "1" && ( -n "$MIGRATION_FILE" || "$ROLLBACK_HIERARCHY" == "1" ) ]]
}

enforce_clean_git() {
  [[ "$REQUIRE_CLEAN_GIT" == "0" || "$REQUIRE_CLEAN_GIT" == "1" ]] ||
    fail "REQUIRE_CLEAN_GIT must be 0 or 1."
  if [[ "$REQUIRE_CLEAN_GIT" == "0" && "$DRY_RUN" != "1" ]]; then
    fail "REQUIRE_CLEAN_GIT=0 is allowed only for an explicit --dry-run."
  fi

  local dirty_count
  dirty_count="$(git -C "$ROOT_DIR" status --porcelain | wc -l | tr -d ' ')"
  if [[ "$dirty_count" != "0" ]]; then
    warn "Git worktree has $dirty_count uncommitted paths."
    [[ "$REQUIRE_CLEAN_GIT" == "0" ]] || fail "Refusing to deploy dirty worktree."
  fi
}

enforce_origin_main_ancestry() {
  production_deploy_path_requested || return 0

  log "Production Git ancestry"
  git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1 ||
    fail "Missing Git remote: origin."
  if ! git -C "$ROOT_DIR" fetch --quiet origin \
    +refs/heads/main:refs/remotes/origin/main; then
    fail "Could not freshly fetch origin/main."
  fi
  git -C "$ROOT_DIR" show-ref --verify --quiet refs/remotes/origin/main ||
    fail "Fresh fetch did not produce origin/main."
  [[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == \
     "$(git -C "$ROOT_DIR" rev-parse origin/main)" ]] ||
    fail "Production deployment requires exact HEAD == freshly fetched origin/main."
  printf 'Git release verified: HEAD exactly matches origin/main.\n'
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  "$@"
}

run_masked() {
  local label="$1"
  shift
  printf '+ %s\n' "$label"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  "$@"
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

confirm_production() {
  if [[ "$DRY_RUN" == "1" || "$YES" == "1" ]]; then
    return 0
  fi
  if [[ "${CONFIRM_PRODUCTION_DEPLOY:-}" == "DEPLOY_GLOBOS_PROD" ]]; then
    return 0
  fi
  if [[ "$SKIP_DB" == "1" && "$SKIP_VERCEL" == "1" ]]; then
    return 0
  fi

  printf 'Production target: Supabase %s, Vercel %s\n' \
    "$POS_PROJECT_REF" "$POS_VERCEL_PROJECT"
  read -r -p "Type DEPLOY_GLOBOS_PROD to continue: " confirm
  [[ "$confirm" == "DEPLOY_GLOBOS_PROD" ]] || fail "Aborted."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --migration)
        shift
        MIGRATION_FILE="${1:-}"
        [[ -n "$MIGRATION_FILE" ]] || fail "--migration requires a file"
        ;;
      --mode)
        shift
        DEPLOY_MODE="${1:-}"
        [[ -n "$DEPLOY_MODE" ]] || fail "--mode requires a value"
        ;;
      --test)
        shift
        [[ -n "${1:-}" ]] || fail "--test requires a file"
        TEST_TARGETS="${TEST_TARGETS:+$TEST_TARGETS }$1"
        ;;
      --no-tests)
        TEST_TARGETS=""
        ;;
      --skip-checks)
        SKIP_CHECKS=1
        ;;
      --skip-auth-check)
        SKIP_AUTH_CHECK=1
        ;;
      --skip-login-smoke)
        SKIP_LOGIN_SMOKE=1
        ;;
      --skip-db)
        SKIP_DB=1
        ;;
      --skip-build)
        SKIP_BUILD=1
        ;;
      --skip-vercel)
        SKIP_VERCEL=1
        ;;
      --rollback-hierarchy)
        ROLLBACK_HIERARCHY=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --yes)
        YES=1
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

preflight() {
  log "Preflight"
  reject_target_overrides
  need_cmd git
  [[ "$DEPLOY_MODE" == "prebuilt" || "$DEPLOY_MODE" == "remote" ]] ||
    fail "DEPLOY_MODE must be prebuilt or remote"

  enforce_clean_git
  enforce_origin_main_ancestry

  [[ -f "$PROJECT_REF_FILE" ]] || fail "Missing project ref file: $PROJECT_REF_FILE"
  local project_ref
  project_ref="$(tr -d '\r\n' < "$PROJECT_REF_FILE")"
  printf 'Supabase linked project: %s\n' "$project_ref"
  [[ "$project_ref" == "$POS_PROJECT_REF" ]] ||
    fail "Linked Supabase project is not POS production ($POS_PROJECT_REF)."

  [[ -f "$ROOT_DIR/.vercel/project.json" ]] ||
    fail "Missing .vercel/project.json. Run vercel link before deploying."
  grep -q "\"projectName\": \"$POS_VERCEL_PROJECT\"" "$ROOT_DIR/.vercel/project.json" ||
    fail "Vercel project name is not $POS_VERCEL_PROJECT."
  grep -q "\"projectId\": \"$POS_VERCEL_PROJECT_ID\"" "$ROOT_DIR/.vercel/project.json" ||
    fail "Vercel project id is not the pinned POS project."
  grep -q "\"orgId\": \"$POS_VERCEL_ORG_ID\"" "$ROOT_DIR/.vercel/project.json" ||
    fail "Vercel org id is not the pinned POS team."
  printf 'Vercel project: %s\n' "$POS_VERCEL_PROJECT"

  if [[ "$SKIP_CHECKS" != "1" ]]; then
    need_cmd dart
    need_cmd flutter
  fi
  if [[ "$SKIP_AUTH_CHECK" != "1" ]]; then
    need_cmd supabase
    [[ -f "$ROOT_DIR/scripts/check_pilot_auth_accounts.sh" ]] ||
      fail "Missing pilot Auth checker: $ROOT_DIR/scripts/check_pilot_auth_accounts.sh"
    [[ -f "$PILOT_AUTH_EMAILS_FILE" ]] ||
      fail "Missing pilot Auth account file: $PILOT_AUTH_EMAILS_FILE"
  fi
  if [[ "$SKIP_LOGIN_SMOKE" != "1" && "$SKIP_VERCEL" != "1" ]]; then
    need_cmd curl
    need_cmd python3
    [[ -f "$PILOT_LOGIN_SMOKE_SCRIPT" ]] ||
      fail "Missing pilot login smoke script: $PILOT_LOGIN_SMOKE_SCRIPT"
  fi
  if [[ "$SKIP_DB" != "1" && ( -n "$MIGRATION_FILE" || "$ROLLBACK_HIERARCHY" == "1" ) ]]; then
    need_cmd supabase
    need_cmd psql
  fi
  if [[ "$DEPLOY_MODE" == "remote" && "$SKIP_BUILD" != "1" ]]; then
    need_cmd flutter
  fi
  if [[ "$SKIP_VERCEL" != "1" ]]; then
    need_cmd vercel
    need_cmd curl
  fi
}

run_auth_check() {
  if [[ "$SKIP_AUTH_CHECK" == "1" ]]; then
    log "Pilot Auth account readiness check skipped"
    return 0
  fi

  log "Pilot Auth account readiness"
  run bash "$ROOT_DIR/scripts/check_pilot_auth_accounts.sh" \
    --file "$PILOT_AUTH_EMAILS_FILE" \
    --expected-project-ref "$POS_PROJECT_REF"
}

run_checks() {
  if [[ "$SKIP_CHECKS" == "1" ]]; then
    log "Checks skipped"
    return 0
  fi

  [[ -f "$ROOT_DIR/pubspec.lock" ]] ||
    fail "Missing pubspec.lock; production checks require locked Flutter dependencies."

  log "Flutter dependency bootstrap"
  run flutter pub get --enforce-lockfile

  log "Static analysis"
  run dart analyze

  if [[ -z "$TEST_TARGETS" ]]; then
    log "Flutter tests skipped"
    return 0
  fi

  log "Flutter tests"
  local target
  for target in $TEST_TARGETS; do
    if [[ "$target" == "all" ]]; then
      run flutter test
    elif [[ -f "$ROOT_DIR/$target" ]]; then
      run flutter test "$target"
    else
      warn "Test target not found, skipping: $target"
    fi
  done
}

parse_linked_pg_exports() {
  local dump_script="$1"
  local line name value
  local host_count=0 port_count=0 user_count=0 password_count=0 database_count=0

  PGHOST=""
  PGPORT=""
  PGUSER=""
  PGPASSWORD=""
  PGDATABASE=""

  while IFS= read -r line; do
    case "$line" in
      'export PGHOST="'*'"') name=PGHOST ;;
      'export PGPORT="'*'"') name=PGPORT ;;
      'export PGUSER="'*'"') name=PGUSER ;;
      'export PGPASSWORD="'*'"') name=PGPASSWORD ;;
      'export PGDATABASE="'*'"') name=PGDATABASE ;;
      export\ PG*) fail "Supabase credential output contained a malformed PG export." ;;
      *) continue ;;
    esac

    value="${line#export $name=\"}"
    value="${value%\"}"
    [[ "$value" != *'"'* && "$value" != *$'\n'* && "$value" != *$'\r'* ]] ||
      fail "Supabase credential output contained an unsafe $name value."

    case "$name" in
      PGHOST) PGHOST="$value"; host_count=$((host_count + 1)) ;;
      PGPORT) PGPORT="$value"; port_count=$((port_count + 1)) ;;
      PGUSER) PGUSER="$value"; user_count=$((user_count + 1)) ;;
      PGPASSWORD) PGPASSWORD="$value"; password_count=$((password_count + 1)) ;;
      PGDATABASE) PGDATABASE="$value"; database_count=$((database_count + 1)) ;;
    esac
  done <<< "$dump_script"

  [[ "$host_count" == "1" && "$port_count" == "1" && "$user_count" == "1" &&
     "$password_count" == "1" && "$database_count" == "1" ]] ||
    fail "Supabase credential output did not contain exactly one required PG export."
}

validate_linked_pg_credentials() {
  local direct_host="db.$POS_PROJECT_REF.supabase.co"

  if [[ "$PGHOST" == "$direct_host" ]]; then
    [[ "$PGPORT" == "5432" ]] || fail "Direct database credential used an unexpected port."
  elif [[ "$PGHOST" =~ ^[a-z0-9-]+\.pooler\.supabase\.com$ ]]; then
    [[ "$PGPORT" == "5432" || "$PGPORT" == "6543" ]] ||
      fail "Pooler database credential used an unexpected port."
  else
    fail "Supabase credential host is not an allowed POS direct or pooler host."
  fi

  if [[ "$PGUSER" == "postgres.$POS_PROJECT_REF" ]]; then
    :
  elif [[ "$PGUSER" == cli_login_* && "$PGUSER" == *"$POS_PROJECT_REF"* ]]; then
    :
  else
    fail "Supabase credential user is not bound to the POS project ref."
  fi
  [[ -n "$PGPASSWORD" ]] || fail "Supabase credential password is empty."
  [[ "$PGDATABASE" == "postgres" ]] || fail "Supabase credential database is not postgres."
}

acquire_linked_pg_credentials() {
  local dump_script
  if ! dump_script="$(supabase db dump --linked --schema public --dry-run 2>/dev/null)"; then
    fail "Unable to acquire temporary linked Supabase database credentials."
  fi

  parse_linked_pg_exports "$dump_script"
  dump_script=""
  validate_linked_pg_credentials
}

run_linked_psql_file() {
  local file="$1"
  local pass_label="$2"
  local role_check_sql
  local -a policy_psql_args=()
  [[ -f "$file" ]] || fail "Missing SQL file: $file"

  if [[ "$(basename "$file")" == "apply_photo_objet_expected_slot_ledger.sql" ]]; then
    local variable
    for variable in \
      PHOTO_OBJET_MONITORING_EFFECTIVE_FROM \
      PHOTO_OBJET_BIENHOA_STORE_ID \
      PHOTO_OBJET_DIAN_STORE_ID \
      PHOTO_OBJET_LONGTHANH_STORE_ID \
      PHOTO_OBJET_THAODIEN_STORE_ID \
      PHOTO_OBJET_QUANGTRUNG_STORE_ID \
      PHOTO_OBJET_NOWZONE_STORE_ID; do
      [[ -n "${!variable:-}" ]] || fail "$variable is required for Photo Objet policy rollout."
    done
    policy_psql_args=(
      -v "photo_policy_effective_from=$PHOTO_OBJET_MONITORING_EFFECTIVE_FROM"
      -v "photo_store_bienhoa=$PHOTO_OBJET_BIENHOA_STORE_ID"
      -v "photo_store_dian=$PHOTO_OBJET_DIAN_STORE_ID"
      -v "photo_store_longthanh=$PHOTO_OBJET_LONGTHANH_STORE_ID"
      -v "photo_store_thaodien=$PHOTO_OBJET_THAODIEN_STORE_ID"
      -v "photo_store_quangtrung=$PHOTO_OBJET_QUANGTRUNG_STORE_ID"
      -v "photo_store_nowzone=$PHOTO_OBJET_NOWZONE_STORE_ID"
    )
  fi

  role_check_sql="DO \$pos_role_check\$
BEGIN
  IF current_user <> '$POS_PSQL_ROLE'
     OR (
       session_user !~ '^cli_login_'
       AND session_user <> '$POS_PSQL_ROLE'
     )
     OR NOT pg_catalog.pg_has_role(session_user, '$POS_PSQL_ROLE', 'MEMBER') THEN
    RAISE EXCEPTION 'POS_PSQL_ROLE_ACTIVATION_FAILED';
  END IF;
END;
\$pos_role_check\$;"

  printf '+ supabase db dump --linked --schema public --dry-run <captured>\n'
  printf '+ PGSSLMODE=require psql -X --no-psqlrc -v ON_ERROR_STOP=1 --single-transaction --command SET_ROLE_POSTGRES --command VERIFY_ROLE'
  if [[ "${#policy_psql_args[@]}" -gt 0 ]]; then
    printf ' --set PHOTO_POLICY_VALUES=<validated>'
  fi
  printf ' --file %q\n' "$file"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  acquire_linked_pg_credentials
  local psql_status=0
  if [[ "${#policy_psql_args[@]}" -gt 0 ]]; then
    PGHOST="$PGHOST" \
      PGPORT="$PGPORT" \
      PGUSER="$PGUSER" \
      PGPASSWORD="$PGPASSWORD" \
      PGDATABASE="$PGDATABASE" \
      PGSSLMODE=require \
      psql -X --no-psqlrc -v ON_ERROR_STOP=1 --single-transaction \
        "${policy_psql_args[@]}" \
        --command "SET ROLE $POS_PSQL_ROLE;" \
        --command "$role_check_sql" \
        --file "$file" || psql_status=$?
  else
    PGHOST="$PGHOST" \
      PGPORT="$PGPORT" \
      PGUSER="$PGUSER" \
      PGPASSWORD="$PGPASSWORD" \
      PGDATABASE="$PGDATABASE" \
      PGSSLMODE=require \
      psql -X --no-psqlrc -v ON_ERROR_STOP=1 --single-transaction \
        --command "SET ROLE $POS_PSQL_ROLE;" \
        --command "$role_check_sql" \
        --file "$file" || psql_status=$?
  fi
  if [[ "$psql_status" -ne 0 ]]; then
    unset PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
    fail "$pass_label failed."
  fi
  unset PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
  printf 'PASS: %s\n' "$pass_label"
}

migration_history_contains_remote_version() {
  local migration_version="$1"
  local migration_list
  if ! migration_list="$(supabase migration list 2>/dev/null)"; then
    fail "Could not list Supabase migration history."
  fi

  awk -F '|' -v version="$migration_version" '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    NF >= 2 && trim($2) == version { found = 1 }
    END { exit(found ? 0 : 1) }
  ' <<< "$migration_list"
}

require_migration_history_absent() {
  local migration_version="$1"
  log "Confirm migration history absence"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ supabase migration list (require remote version %q absent)\n' "$migration_version"
    return 0
  fi
  if migration_history_contains_remote_version "$migration_version"; then
    fail "Remote migration history already contains $migration_version."
  fi
  printf 'Migration history does not contain remote version %s.\n' "$migration_version"
}

require_migration_history_present() {
  local migration_version="$1"
  log "Confirm migration history presence"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ supabase migration list (require remote version %q present)\n' "$migration_version"
    return 0
  fi
  migration_history_contains_remote_version "$migration_version" ||
    fail "Remote migration history does not contain $migration_version."
  printf 'Migration history contains remote version %s.\n' "$migration_version"
}

apply_migration() {
  if [[ "$SKIP_DB" == "1" ]]; then
    log "Supabase migration skipped"
    return 0
  fi
  if [[ -z "$MIGRATION_FILE" ]]; then
    log "No Supabase migration requested"
    return 0
  fi

  local migration_path="$MIGRATION_FILE"
  [[ "$migration_path" = /* ]] || migration_path="$ROOT_DIR/$migration_path"
  [[ -f "$migration_path" ]] || fail "Missing migration: $migration_path"

  local migration_name
  local migration_version
  local verification_complete=0
  migration_name="$(basename "$migration_path")"
  migration_version="${migration_name%%_*}"
  [[ "$migration_version" =~ ^[0-9]+$ ]] ||
    fail "Migration file must start with a numeric version: $migration_name"

  case "$migration_name" in
    20260711090000_legal_entity_brand_store_hierarchy.sql|\
    20260713120000_photo_objet_expected_slot_ledger.sql)
      verification_complete=1
      ;;
  esac
  [[ "$verification_complete" == "1" ]] ||
    fail "Migration $migration_name has no explicit verification phase."

  require_migration_history_absent "$migration_version"

  log "Apply Supabase migration"
  if [[ "$migration_name" == "20260711090000_legal_entity_brand_store_hierarchy.sql" ]]; then
    log "Hierarchy migration preflight"
    run_linked_psql_file \
      "$ROOT_DIR/scripts/preflight_legal_entity_brand_store_hierarchy.sql" \
      "hierarchy migration preflight"
  elif [[ "$migration_name" == "20260713120000_photo_objet_expected_slot_ledger.sql" ]]; then
    log "Photo Objet expected-slot migration preflight"
    run_linked_psql_file \
      "$ROOT_DIR/scripts/preflight_photo_objet_expected_slot_ledger.sql" \
      "Photo Objet expected-slot migration preflight"
  fi
  if [[ "$migration_name" == "20260713120000_photo_objet_expected_slot_ledger.sql" ]]; then
    log "Apply Photo Objet ledger, approved policies, and first slots atomically"
    run_linked_psql_file \
      "$ROOT_DIR/scripts/apply_photo_objet_expected_slot_ledger.sql" \
      "migration $migration_version with approved Photo Objet policies"
  else
    run_linked_psql_file "$migration_path" "migration $migration_version"
  fi

  if [[ "$migration_name" == "20260711090000_legal_entity_brand_store_hierarchy.sql" ]]; then
    log "Hierarchy migration verification"
    run_linked_psql_file \
      "$ROOT_DIR/scripts/verify_legal_entity_brand_store_hierarchy.sql" \
      "hierarchy migration verification"
  elif [[ "$migration_name" == "20260713120000_photo_objet_expected_slot_ledger.sql" ]]; then
    log "Photo Objet expected-slot migration verification"
    run_linked_psql_file \
      "$ROOT_DIR/scripts/verify_photo_objet_expected_slot_ledger.sql" \
      "Photo Objet expected-slot migration verification"
  fi

  log "Repair Supabase migration history"
  run supabase migration repair "$migration_version" --status applied --yes
  require_migration_history_present "$migration_version"
}

rollback_hierarchy() {
  [[ "$ROLLBACK_HIERARCHY" == "1" ]] || return 0
  [[ "$SKIP_DB" != "1" ]] || fail "Hierarchy rollback cannot be combined with --skip-db."
  [[ -z "$MIGRATION_FILE" ]] || fail "Hierarchy rollback cannot be combined with --migration."
  [[ "${CONFIRM_HIERARCHY_ROLLBACK:-}" == "ROLLBACK_HIERARCHY_20260711090000" ]] ||
    fail "Set CONFIRM_HIERARCHY_ROLLBACK=ROLLBACK_HIERARCHY_20260711090000 to approve destructive rollback."

  require_migration_history_present 20260711090000

  log "DESTRUCTIVE hierarchy rollback"
  run_linked_psql_file \
    "$ROOT_DIR/scripts/rollback_legal_entity_brand_store_hierarchy.sql" \
    "hierarchy rollback"

  log "Repair rolled back Supabase migration history"
  run supabase migration repair 20260711090000 --status reverted --yes
  require_migration_history_absent 20260711090000
}

ensure_flutter_env() {
  load_env
  reject_target_overrides
  [[ -n "${SUPABASE_URL:-}" ]] || fail "SUPABASE_URL is not set."
  [[ -n "${SUPABASE_ANON_KEY:-}" ]] || fail "SUPABASE_ANON_KEY is not set."

  local normalized_url
  local expected_url
  normalized_url="${SUPABASE_URL%/}"
  expected_url="https://$POS_PROJECT_REF.supabase.co"
  [[ "$normalized_url" == "$expected_url" ]] ||
    fail "SUPABASE_URL is not production $expected_url."
  SUPABASE_URL="$normalized_url"
}

local_flutter_build() {
  if [[ "$DEPLOY_MODE" != "remote" || "$SKIP_BUILD" == "1" ]]; then
    return 0
  fi

  log "Local Flutter web build precheck"
  ensure_flutter_env
  run_masked \
    "flutter build web --release --dart-define=SUPABASE_URL=<set> --dart-define=SUPABASE_ANON_KEY=<set> --no-wasm-dry-run" \
    flutter build web --release \
      --dart-define=SUPABASE_URL="$SUPABASE_URL" \
      --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
      --no-wasm-dry-run
}

deploy_vercel() {
  if [[ "$SKIP_VERCEL" == "1" ]]; then
    log "Vercel deploy skipped"
    return 0
  fi

  ensure_flutter_env

  local deploy_log
  deploy_log="$(mktemp)"

  if [[ "$DEPLOY_MODE" == "prebuilt" ]]; then
    log "Vercel local build"
    run vercel build --prod
    log "Vercel prebuilt deploy"
    printf '+ vercel deploy --prebuilt --prod --yes\n'
    if [[ "$DRY_RUN" != "1" ]]; then
      vercel deploy --prebuilt --prod --yes 2>&1 | tee "$deploy_log"
    fi
  else
    log "Vercel remote deploy"
    printf '+ vercel deploy --prod --yes\n'
    if [[ "$DRY_RUN" != "1" ]]; then
      vercel deploy --prod --yes 2>&1 | tee "$deploy_log"
    fi
  fi

  local deployment_url
  if [[ "$DRY_RUN" != "1" ]]; then
    deployment_url="$(grep -Eo 'https://[^[:space:]]+\.vercel\.app[^[:space:]]*' "$deploy_log" | tail -1 | tr -d '\r')"
    if [[ -n "$deployment_url" ]]; then
      printf 'Deployment URL: %s\n' "$deployment_url"
    else
      warn "Could not parse deployment URL from Vercel output."
    fi
  fi

  log "Live URL check"
  run curl -fsSI -L "$LIVE_URL"
}

run_login_smoke() {
  if [[ "$SKIP_VERCEL" == "1" ]]; then
    log "Pilot login smoke skipped because Vercel deploy was skipped"
    return 0
  fi
  if [[ "$SKIP_LOGIN_SMOKE" == "1" ]]; then
    log "Pilot login smoke skipped"
    warn "Do not report this deploy as login-ready until a pilot login smoke passes."
    return 0
  fi

  log "Pilot login smoke"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ PILOT_SMOKE_EMAIL=<set> PILOT_SMOKE_PASSWORD=<set> bash %q --expected-project-ref %q\n' \
      "$PILOT_LOGIN_SMOKE_SCRIPT" "$POS_PROJECT_REF"
    return 0
  fi

  [[ -n "${PILOT_SMOKE_EMAIL:-}" ]] ||
    fail "PILOT_SMOKE_EMAIL is required for post-deploy pilot login smoke."
  [[ -n "${PILOT_SMOKE_PASSWORD:-}" ]] ||
    fail "PILOT_SMOKE_PASSWORD is required for post-deploy pilot login smoke."

  run bash "$PILOT_LOGIN_SMOKE_SCRIPT" \
    --email "$PILOT_SMOKE_EMAIL" \
    --expected-project-ref "$POS_PROJECT_REF"
}

main() {
  parse_args "$@"
  cd "$ROOT_DIR"
  confirm_production
  preflight
  if [[ "$ROLLBACK_HIERARCHY" == "1" ]]; then
    rollback_hierarchy
    log "Rollback flow completed"
    return 0
  fi
  run_auth_check
  run_checks
  apply_migration
  local_flutter_build
  deploy_vercel
  run_login_smoke

  log "Deployment flow completed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
