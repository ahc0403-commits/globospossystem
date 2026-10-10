#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"

readonly POS_PROJECT_REF="ynriuoomotxuwhuxxmhj"
readonly POS_PSQL_ROLE="postgres"
readonly POS_VERCEL_PROJECT="globospossystem"
readonly POS_VERCEL_PROJECT_ID="prj_glOhZuHqHUHyAsGaSx5BVip3MIJJ"
readonly POS_VERCEL_ORG_ID="team_4AfACJKDlP09zRqoJKce3Tib"
readonly POS_GITHUB_ORG="ahc0403-commits"
readonly POS_GITHUB_REPO="globospossystem"
readonly POS_REQUIRED_GITHUB_CHECK="POS release contract"
readonly LIVE_URL="https://globospossystem.vercel.app"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.local}"
MIGRATION_FILE="${MIGRATION_FILE:-}"
TEST_TARGETS="${TEST_TARGETS:-test/pilot_feedback_closure_contract_test.dart}"
DEPLOY_MODE="${DEPLOY_MODE:-prebuilt}"
PRODUCTION_AUTH_EMAILS_FILE="${PRODUCTION_AUTH_EMAILS_FILE:-${PILOT_AUTH_EMAILS_FILE:-$ROOT_DIR/docs/pos/pos_required_production_auth_emails.txt}}"
PILOT_LOGIN_SMOKE_SCRIPT="${PILOT_LOGIN_SMOKE_SCRIPT:-$ROOT_DIR/scripts/smoke_pilot_login.sh}"
FIXED_ACCOUNT_SMOKE_SCRIPT="${FIXED_ACCOUNT_SMOKE_SCRIPT:-$ROOT_DIR/scripts/smoke_fixed_pos_account_login.sh}"

YES="${YES:-0}"
DRY_RUN=0
SKIP_CHECKS="${SKIP_CHECKS:-0}"
SKIP_AUTH_CHECK="${SKIP_AUTH_CHECK:-0}"
SKIP_LOGIN_SMOKE="${SKIP_LOGIN_SMOKE:-0}"
SKIP_SMOKE_TESTS="${SKIP_SMOKE_TESTS:-0}"
SKIP_DB="${SKIP_DB:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_VERCEL="${SKIP_VERCEL:-0}"
REQUIRE_CLEAN_GIT="${REQUIRE_CLEAN_GIT:-1}"
ROLLBACK_HIERARCHY=0
DB_ONLY=0
MIGRATION_OPTION_SET=0

# shellcheck source=scripts/lib/production_migration_gate.sh
source "$ROOT_DIR/scripts/lib/production_migration_gate.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy_pos_production.sh [options]

Default flow:
  preflight -> production Auth and test-data hygiene -> locked Flutter dependency bootstrap ->
  dart analyze -> focused tests ->
  optional DB migration -> vercel build --prod ->
  vercel deploy --prebuilt --prod -> live HTTP check -> operational login smoke

DB-only flow:
  clean exact-main/source and production Supabase preflight -> locked Flutter
  dependency bootstrap -> dart analyze -> tests -> rollback readiness ->
  migration-history absence -> SQL preflight -> atomic apply -> verification ->
  migration-history confirmation

  DB-only never invokes production Auth/account checks or login smoke, never
  requires login credentials, and never creates, resets, or mutates accounts.
  Auth, Vercel, live HTTP, and login readiness are not applicable.

Options:
  --migration FILE   Apply one Supabase migration before deploying.
  --db-only          Run the required migration gates without Auth or Vercel work.
                     Requires --migration and all checks; incompatible with
                     remote mode, skip options, and rollback.
  --mode MODE        prebuilt (default) or remote.
  --test FILE        Add a flutter test target. Use "all" for flutter test.
  --no-tests         Skip flutter test targets while keeping dart analyze.
  --skip-checks      Skip dart analyze and flutter tests.
  --skip-auth-check  Skip required production operational Auth readiness check.
  --skip-login-smoke Skip post-deploy operational login smoke. Report as blocker-risk.
  --skip-smoke-tests Skip synthetic HTTP and login probes; verify deployment
                     metadata and the remote origin digest instead. All source,
                     CI, Auth readiness, migration and build gates still apply.
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
  PRODUCTION_AUTH_EMAILS_FILE=docs/pos/pos_required_production_auth_emails.txt
  FIXED_SMOKE_ACCOUNT_CODE=<existing fixed POS code>
  FIXED_SMOKE_PASSWORD=<set securely in environment; never print it>
  PILOT_SMOKE_EMAIL=<legacy generic helper only; not used by production release>
  PILOT_SMOKE_PASSWORD=<legacy generic helper only; never print it>
  ALLOWED_ORIGINS=https://globospossystem.vercel.app
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
  # Every non-help invocation can deploy POS Edge functions, DB, or web.
  # Therefore no skip combination is allowed to bypass exact-main ancestry.
  return 0
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

enforce_required_github_check() {
  production_deploy_path_requested || return 0

  log "Required GitHub Actions release check"
  need_cmd gh

  local release_sha check_runs
  release_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  if ! check_runs="$(
    gh api \
      "repos/$POS_GITHUB_ORG/$POS_GITHUB_REPO/commits/$release_sha/check-runs" \
      --paginate \
      --jq ".check_runs[] | select(.name == \"$POS_REQUIRED_GITHUB_CHECK\" and .app.slug == \"github-actions\") | [.status, .conclusion, .html_url] | @tsv"
  )"; then
    fail "Could not read required GitHub Actions checks for exact main SHA $release_sha."
  fi

  grep -Eq '^completed[[:space:]]+success([[:space:]]|$)' <<< "$check_runs" ||
    fail "Required GitHub Actions check '$POS_REQUIRED_GITHUB_CHECK' has not succeeded for exact main SHA $release_sha."
  printf 'GitHub release verified: %s succeeded for %s.\n' \
    "$POS_REQUIRED_GITHUB_CHECK" "$release_sha"
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

verify_allowed_production_origins() {
  local configured="${ALLOWED_ORIGINS:-}"
  [[ "$configured" == "$LIVE_URL" ]] ||
    fail "ALLOWED_ORIGINS must be exactly $LIVE_URL for the POS production release."
  [[ "$configured" != *'*'* && "$configured" != *','* ]] ||
    fail "Wildcard or multiple production origins are forbidden."
  printf 'Allowed production origin verified: %s\n' "$configured"
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

  if [[ "$DB_ONLY" == "1" ]]; then
    printf 'Production DB-only target: Supabase %s\n' "$POS_PROJECT_REF"
  else
    printf 'Production target: Supabase %s, Vercel %s\n' \
      "$POS_PROJECT_REF" "$POS_VERCEL_PROJECT"
  fi
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
        MIGRATION_OPTION_SET=1
        ;;
      --db-only)
        DB_ONLY=1
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
      --skip-smoke-tests)
        SKIP_SMOKE_TESTS=1
        SKIP_LOGIN_SMOKE=1
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
  [[ "$SKIP_SMOKE_TESTS" == "0" || "$SKIP_SMOKE_TESTS" == "1" ]] || fail "SKIP_SMOKE_TESTS must be 0 or 1."
  if [[ "$SKIP_SMOKE_TESTS" == "1" ]]; then SKIP_LOGIN_SMOKE=1; fi
}

validate_db_only_options() {
  [[ "$DB_ONLY" == "1" ]] || return 0

  [[ "$MIGRATION_OPTION_SET" == "1" && -n "$MIGRATION_FILE" ]] ||
    fail "--db-only requires --migration FILE."
  [[ "$DEPLOY_MODE" == "prebuilt" ]] ||
    fail "--db-only is incompatible with non-default deployment mode $DEPLOY_MODE."
  [[ "$SKIP_CHECKS" == "0" ]] || fail "--db-only is incompatible with --skip-checks."
  [[ -n "$TEST_TARGETS" ]] || fail "--db-only is incompatible with --no-tests."
  [[ "$SKIP_AUTH_CHECK" == "0" ]] ||
    fail "--db-only is incompatible with --skip-auth-check; Auth is not applicable in DB-only mode."
  [[ "$SKIP_LOGIN_SMOKE" == "0" ]] ||
    fail "--db-only is incompatible with --skip-login-smoke; login smoke is not applicable in DB-only mode."
  [[ "$SKIP_DB" == "0" ]] || fail "--db-only is incompatible with --skip-db."
  [[ "$SKIP_BUILD" == "0" ]] || fail "--db-only is incompatible with --skip-build."
  [[ "$SKIP_VERCEL" == "0" ]] ||
    fail "--db-only is incompatible with --skip-vercel; Vercel is already not applicable."
  [[ "$ROLLBACK_HIERARCHY" == "0" ]] ||
    fail "--db-only is incompatible with --rollback-hierarchy."
}

preflight() {
  log "Preflight"
  reject_target_overrides
  need_cmd git
  if [[ "$SKIP_SMOKE_TESTS" == "1" ]]; then need_cmd python3; fi
  [[ "$DEPLOY_MODE" == "prebuilt" || "$DEPLOY_MODE" == "remote" ]] ||
    fail "DEPLOY_MODE must be prebuilt or remote"

  enforce_clean_git
  enforce_origin_main_ancestry
  enforce_required_github_check

  [[ -f "$PROJECT_REF_FILE" ]] || fail "Missing project ref file: $PROJECT_REF_FILE"
  local project_ref
  project_ref="$(tr -d '\r\n' < "$PROJECT_REF_FILE")"
  printf 'Supabase linked project: %s\n' "$project_ref"
  [[ "$project_ref" == "$POS_PROJECT_REF" ]] ||
    fail "Linked Supabase project is not POS production ($POS_PROJECT_REF)."

  if [[ "$DB_ONLY" != "1" ]]; then
    [[ -f "$ROOT_DIR/.vercel/project.json" ]] ||
      fail "Missing .vercel/project.json. Run vercel link before deploying."
    grep -Eq "\"projectName\"[[:space:]]*:[[:space:]]*\"$POS_VERCEL_PROJECT\"" "$ROOT_DIR/.vercel/project.json" ||
      fail "Vercel project name is not $POS_VERCEL_PROJECT."
    grep -Eq "\"projectId\"[[:space:]]*:[[:space:]]*\"$POS_VERCEL_PROJECT_ID\"" "$ROOT_DIR/.vercel/project.json" ||
      fail "Vercel project id is not the pinned POS project."
    grep -Eq "\"orgId\"[[:space:]]*:[[:space:]]*\"$POS_VERCEL_ORG_ID\"" "$ROOT_DIR/.vercel/project.json" ||
      fail "Vercel org id is not the pinned POS team."
    printf 'Vercel project: %s\n' "$POS_VERCEL_PROJECT"
  fi

  if [[ "$SKIP_CHECKS" != "1" ]]; then
    need_cmd dart
    need_cmd flutter
    need_cmd deno
  fi
  if [[ "$DB_ONLY" != "1" ]]; then
    need_cmd supabase
    [[ -f "$ROOT_DIR/supabase/functions/create_staff_user/index.ts" ]] ||
      fail "Missing create_staff_user Edge function."
    [[ -f "$ROOT_DIR/supabase/functions/provision-fixed-pos-account/index.ts" ]] ||
      fail "Missing provision-fixed-pos-account Edge function."
    [[ -f "$ROOT_DIR/supabase/functions/complete-initial-password-change/index.ts" ]] ||
      fail "Missing complete-initial-password-change Edge function."
    [[ -f "$ROOT_DIR/supabase/functions/sepay-webhook/index.ts" ]] ||
      fail "Missing sepay-webhook Edge function."
    [[ -f "$ROOT_DIR/supabase/functions/emergency-fulfillment-dispatcher/index.ts" ]] ||
      fail "Missing emergency-fulfillment-dispatcher Edge function."
    [[ -f "$ROOT_DIR/supabase/functions/public-receipt/index.ts" ]] ||
      fail "Missing public-receipt Edge function."
    [[ -f "$ROOT_DIR/supabase/functions/direct-order-public/index.ts" ]] ||
      fail "Missing direct-order-public Edge function."
    [[ -f "$ROOT_DIR/supabase/functions/direct-order-notification-dispatcher/index.ts" ]] ||
      fail "Missing direct-order-notification-dispatcher Edge function."
    [[ -f "$ROOT_DIR/supabase/functions/direct-order-translation-dispatcher/index.ts" ]] ||
      fail "Missing direct-order-translation-dispatcher Edge function."
  fi
  if [[ "$DB_ONLY" != "1" && "$SKIP_AUTH_CHECK" != "1" ]]; then
    [[ -f "$ROOT_DIR/scripts/check_pilot_auth_accounts.sh" ]] ||
      fail "Missing production Auth checker: $ROOT_DIR/scripts/check_pilot_auth_accounts.sh"
    [[ -f "$PRODUCTION_AUTH_EMAILS_FILE" ]] ||
      fail "Missing production Auth account file: $PRODUCTION_AUTH_EMAILS_FILE"
  fi
  if [[ "$DB_ONLY" != "1" && "$SKIP_LOGIN_SMOKE" != "1" && "$SKIP_VERCEL" != "1" ]]; then
    need_cmd curl
    need_cmd python3
    [[ -f "$FIXED_ACCOUNT_SMOKE_SCRIPT" ]] ||
      fail "Missing fixed POS account smoke script: $FIXED_ACCOUNT_SMOKE_SCRIPT"
  fi
  if [[ "$SKIP_DB" != "1" && ( -n "$MIGRATION_FILE" || "$ROLLBACK_HIERARCHY" == "1" ) ]]; then
    need_cmd supabase
    need_cmd psql
  fi
  if [[ "$DB_ONLY" != "1" && "$DEPLOY_MODE" == "remote" && "$SKIP_BUILD" != "1" ]]; then
    need_cmd flutter
  fi
  if [[ "$DB_ONLY" != "1" && "$SKIP_VERCEL" != "1" ]]; then
    need_cmd vercel
    need_cmd curl
  fi
}

verify_vercel_firebase_web_env() {
  if [[ "$SKIP_VERCEL" == "1" ]]; then
    return 0
  fi

  log "Vercel Firebase web push environment"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ vercel env ls production; require Firebase web config names only\n'
    return 0
  fi

  local env_listing
  env_listing="$(vercel env ls production --no-color 2>&1)" ||
    fail "Could not inspect Vercel production environment names."

  local env_name
  for env_name in \
    FIREBASE_API_KEY \
    FIREBASE_APP_ID \
    FIREBASE_MESSAGING_SENDER_ID \
    FIREBASE_PROJECT_ID \
    FIREBASE_WEB_VAPID_KEY; do
    grep -Eq "^[[:space:]]*$env_name[[:space:]]" <<<"$env_listing" ||
      fail "Vercel production environment is missing $env_name."
  done
  printf 'Vercel Firebase web push environment: ready.\n'
}

run_auth_check() {
  if [[ "$SKIP_AUTH_CHECK" == "1" ]]; then
    log "Production Auth and test-data hygiene check skipped"
    return 0
  fi

  log "Production Auth and test-data hygiene"
  run bash "$ROOT_DIR/scripts/check_pilot_auth_accounts.sh" \
    --file "$PRODUCTION_AUTH_EMAILS_FILE" \
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

  log "Deliberry retirement regression tests"
  run bash "$ROOT_DIR/test/deliberry_retirement_sql_test.sh"
  run deno test --no-config \
    "$ROOT_DIR/supabase/functions/_shared/retired_deliberry_test.ts"

  log "Password lifecycle Edge tests"
  run deno test --allow-env=ALLOWED_ORIGINS \
    "$ROOT_DIR/supabase/functions/complete-initial-password-change/index_test.ts"

  log "SePay webhook Edge tests"
  run deno test \
    "$ROOT_DIR/supabase/functions/sepay-webhook/index_test.ts"

  log "Emergency fulfilment Edge tests"
  run deno test \
    "$ROOT_DIR/supabase/functions/emergency-fulfillment-dispatcher/index_test.ts"

  log "Public receipt Edge security tests"
  run deno test --config \
    "$ROOT_DIR/supabase/functions/public-receipt/deno.json" \
    "$ROOT_DIR/supabase/functions/public-receipt/index_test.ts"

  log "Direct order Edge security tests"
  run deno fmt --check \
    "$ROOT_DIR/supabase/functions/direct-order-public/index.ts" \
    "$ROOT_DIR/supabase/functions/direct-order-public/index_test.ts" \
    "$ROOT_DIR/supabase/functions/direct-order-public/deno.json"
  run deno lint \
    "$ROOT_DIR/supabase/functions/direct-order-public/index.ts" \
    "$ROOT_DIR/supabase/functions/direct-order-public/index_test.ts"
  run deno check --config \
    "$ROOT_DIR/supabase/functions/direct-order-public/deno.json" \
    "$ROOT_DIR/supabase/functions/direct-order-public/index.ts" \
    "$ROOT_DIR/supabase/functions/direct-order-public/index_test.ts"
  run deno test --config \
    "$ROOT_DIR/supabase/functions/direct-order-public/deno.json" \
    "$ROOT_DIR/supabase/functions/direct-order-public/index_test.ts"
  run deno fmt --check \
    "$ROOT_DIR/supabase/functions/_shared/direct_order_push.ts" \
    "$ROOT_DIR/supabase/functions/direct-order-notification-dispatcher"
  run deno lint \
    "$ROOT_DIR/supabase/functions/_shared/direct_order_push.ts" \
    "$ROOT_DIR/supabase/functions/direct-order-notification-dispatcher"
  run deno check --config \
    "$ROOT_DIR/supabase/functions/direct-order-notification-dispatcher/deno.json" \
    "$ROOT_DIR/supabase/functions/direct-order-notification-dispatcher/index.ts"
  run deno test --config \
    "$ROOT_DIR/supabase/functions/direct-order-notification-dispatcher/deno.json" \
    "$ROOT_DIR/supabase/functions/direct-order-notification-dispatcher/index_test.ts"
  run deno fmt --check "$ROOT_DIR/supabase/functions/direct-order-translation-dispatcher"
  run deno lint "$ROOT_DIR/supabase/functions/direct-order-translation-dispatcher"
  run deno check --config "$ROOT_DIR/supabase/functions/direct-order-translation-dispatcher/deno.json" "$ROOT_DIR/supabase/functions/direct-order-translation-dispatcher/index.ts"
  run deno test --config "$ROOT_DIR/supabase/functions/direct-order-translation-dispatcher/deno.json" "$ROOT_DIR/supabase/functions/direct-order-translation-dispatcher/index_test.ts"

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
    elif [[ "$DB_ONLY" == "1" ]]; then
      fail "DB-only test target not found: $target"
    else
      warn "Test target not found, skipping: $target"
    fi
  done
}

verify_sepay_alert_secrets() {
  log "SePay webhook secret readiness"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ supabase secrets list --project-ref %q; require secret names only\n' \
      "$POS_PROJECT_REF"
    return 0
  fi

  local secret_names
  secret_names="$(supabase secrets list --project-ref "$POS_PROJECT_REF" 2>/dev/null | awk -F '|' 'NF >= 2 {gsub(/[[:space:]]/, "", $1); print $1}')" ||
    fail "Could not inspect Supabase Edge secret names."
  local required_secret
  for required_secret in \
    SEPAY_WEBHOOK_SECRET \
    CRON_SECRET \
    FIREBASE_SERVICE_ACCOUNT_JSON \
    DIGITAL_RECEIPT_RATE_LIMIT_SECRET \
    PUBLIC_RECEIPT_SUPABASE_SECRET_KEY_NAME; do
    grep -Fxq "$required_secret" <<<"$secret_names" ||
      fail "Missing required Supabase Edge secret: $required_secret"
  done
}

verify_direct_order_secrets() {
  log "Direct order Edge secret readiness"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ supabase secrets list --project-ref %q; require direct-order secret names only\n' \
      "$POS_PROJECT_REF"
    return 0
  fi

  local secret_names
  secret_names="$(supabase secrets list --project-ref "$POS_PROJECT_REF" 2>/dev/null | awk -F '|' 'NF >= 2 {gsub(/[[:space:]]/, "", $1); print $1}')" ||
    fail "Could not inspect Supabase Edge secret names for direct orders."

  local required_secret
  for required_secret in \
    SUPABASE_SECRET_KEYS \
    DIRECT_ORDER_RATE_LIMIT_SECRET \
    DIRECT_ORDER_CLEANUP_SECRET \
    OPENAI_API_KEY \
    DIRECT_ORDER_TRANSLATION_CRON_SECRET; do
    grep -Fxq "$required_secret" <<<"$secret_names" ||
      fail "Missing required direct-order Edge secret: $required_secret"
  done

  if ! grep -Fxq DIRECT_ORDER_SUPABASE_SECRET_KEY_NAME <<<"$secret_names" &&
     ! grep -Fxq PUBLIC_RECEIPT_SUPABASE_SECRET_KEY_NAME <<<"$secret_names"; then
    fail "Missing direct-order or public-receipt Supabase secret-key selector."
  fi

  # Delivery addresses are entered manually; no map-provider secret is needed.
  printf 'Direct order Edge secret names: ready.\n'
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
    [[ "$PGUSER" == "postgres" || "$PGUSER" == cli_login_* ]] ||
      fail "Direct POS PG user is not an approved temporary login."
  elif [[ "$PGHOST" =~ ^[a-z0-9-]+\.pooler\.supabase\.com$ ]]; then
    if [[ "$DB_ONLY" == "1" ]]; then
      [[ "$PGPORT" == "5432" ]] ||
        fail "DB-only requires the Supabase Shared Session Pooler on port 5432."
    else
      [[ "$PGPORT" == "5432" || "$PGPORT" == "6543" ]] ||
        fail "Pooler database credential used an unexpected port."
    fi
    [[ "$PGUSER" == "postgres.$POS_PROJECT_REF" || \
       ( "$PGUSER" == cli_login_* && "$PGUSER" == *"$POS_PROJECT_REF"* ) ]] ||
      fail "Pooler database credential user is not bound to the POS project ref."
  else
    fail "Supabase credential host is not an allowed POS direct or pooler host."
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

  if [[ "$(basename "$file")" == "apply_restaurant_daily_cutoff.sql" ]]; then
    [[ -n "${RESTAURANT_CUTOFF_STORE_IDS:-}" ]] ||
      fail "RESTAURANT_CUTOFF_STORE_IDS is required for Restaurant cutoff rollout."
    [[ "$RESTAURANT_CUTOFF_STORE_IDS" =~ ^[0-9a-fA-F-]{36}(,[0-9a-fA-F-]{36})*$ ]] ||
      fail "RESTAURANT_CUTOFF_STORE_IDS must be a comma-separated UUID list."
    policy_psql_args=(
      -v "restaurant_cutoff_store_ids=$RESTAURANT_CUTOFF_STORE_IDS"
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
    printf ' --set RESTAURANT_CUTOFF_VALUES=<validated>'
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
  apply_migration_by_convention "$MIGRATION_FILE"
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
    "flutter build web --release --dart-define=SUPABASE_URL=<set> --dart-define=SUPABASE_ANON_KEY=<set> --dart-define=FIREBASE_*=<optional> --no-wasm-dry-run" \
    flutter build web --release \
      --dart-define=SUPABASE_URL="$SUPABASE_URL" \
      --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" \
      --dart-define=FIREBASE_API_KEY="${FIREBASE_API_KEY:-}" \
      --dart-define=FIREBASE_APP_ID="${FIREBASE_APP_ID:-}" \
      --dart-define=FIREBASE_MESSAGING_SENDER_ID="${FIREBASE_MESSAGING_SENDER_ID:-}" \
      --dart-define=FIREBASE_PROJECT_ID="${FIREBASE_PROJECT_ID:-}" \
      --dart-define=FIREBASE_WEB_VAPID_KEY="${FIREBASE_WEB_VAPID_KEY:-}" \
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
  local release_sha
  release_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  local -a release_meta=(
    --meta "githubCommitSha=$release_sha"
    --meta "githubCommitRef=main"
    --meta "githubCommitOrg=$POS_GITHUB_ORG"
    --meta "githubCommitRepo=$POS_GITHUB_REPO"
  )

  if [[ "$DEPLOY_MODE" == "prebuilt" ]]; then
    log "Vercel local build"
    run vercel build --prod
    log "Vercel prebuilt deploy"
    printf '+ vercel deploy --prebuilt --prod --yes --meta <exact-main-provenance>\n'
    if [[ "$DRY_RUN" != "1" ]]; then
      vercel deploy --prebuilt --prod --yes "${release_meta[@]}" 2>&1 | tee "$deploy_log"
    fi
  else
    log "Vercel remote deploy"
    printf '+ vercel deploy --prod --yes --meta <exact-main-provenance>\n'
    if [[ "$DRY_RUN" != "1" ]]; then
      vercel deploy --prod --yes "${release_meta[@]}" 2>&1 | tee "$deploy_log"
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

  if [[ "$SKIP_SMOKE_TESTS" == "1" ]]; then
    log "Vercel production deployment metadata"
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '+ vercel inspect <deployment> and production alias --json; require matching READY production IDs\n'
      return 0
    fi
    local unique_url built_metadata alias_metadata
    unique_url="$(grep -Eo 'https://[^[:space:]]+\.vercel\.app[^[:space:]]*' "$deploy_log" | head -1 | tr -d '\r')"
    [[ -n "$unique_url" ]] || fail "Vercel deployment URL is unavailable for metadata verification."
    built_metadata="$(mktemp)"; alias_metadata="$(mktemp)"
    vercel inspect "$unique_url" --json > "$built_metadata" || { rm -f "$built_metadata" "$alias_metadata"; fail "Cannot inspect deployed build."; }
    vercel inspect "$LIVE_URL" --json > "$alias_metadata" || { rm -f "$built_metadata" "$alias_metadata"; fail "Cannot inspect production alias."; }
    if ! python3 - "$built_metadata" "$alias_metadata" <<'PYVERCELMETADATA'
import json,sys
from pathlib import Path
built,alias=[json.loads(Path(p).read_text()) for p in sys.argv[1:]]
assert built['id']==alias['id'], 'Production alias does not point to the deployed build'
assert all(row.get('readyState')=='READY' and row.get('target')=='production' for row in [built,alias]), 'Production deployment is not READY'
print('Vercel build and production alias: READY (metadata; no HTTP probe).')
PYVERCELMETADATA
    then rm -f "$built_metadata" "$alias_metadata"; fail "Production deployment metadata verification failed."; fi
    rm -f "$built_metadata" "$alias_metadata"
    return 0
  fi
  log "Live URL check"
  run curl -fsSI -L "$LIVE_URL"
}

deploy_pos_edge_functions() {
  log "POS Edge functions deploy"
  run supabase functions deploy create_staff_user --project-ref "$POS_PROJECT_REF"
  run supabase functions deploy provision-fixed-pos-account \
    --project-ref "$POS_PROJECT_REF"
  run supabase functions deploy complete-initial-password-change \
    --project-ref "$POS_PROJECT_REF"
  run supabase functions deploy sepay-webhook --no-verify-jwt \
    --project-ref "$POS_PROJECT_REF"
  run supabase functions deploy emergency-fulfillment-dispatcher \
    --no-verify-jwt --project-ref "$POS_PROJECT_REF"
  run supabase functions deploy public-receipt \
    --no-verify-jwt --project-ref "$POS_PROJECT_REF"
  run supabase functions deploy direct-order-public \
    --no-verify-jwt --project-ref "$POS_PROJECT_REF"
  run supabase functions deploy direct-order-notification-dispatcher \
    --no-verify-jwt --project-ref "$POS_PROJECT_REF"
  run supabase functions deploy direct-order-translation-dispatcher \
    --no-verify-jwt --project-ref "$POS_PROJECT_REF"
  # Retired endpoints must replace any previously deployed active handlers.
  run supabase functions deploy deliberry-webhook \
    --no-verify-jwt --project-ref "$POS_PROJECT_REF"
  run supabase functions deploy deliberry-dispatcher \
    --no-verify-jwt --project-ref "$POS_PROJECT_REF"
  run supabase functions deploy generate-settlement \
    --no-verify-jwt --project-ref "$POS_PROJECT_REF"
  run supabase functions deploy generate_delivery_settlement \
    --no-verify-jwt --project-ref "$POS_PROJECT_REF"
}

verify_no_smoke_edge_metadata() {
  [[ "$SKIP_SMOKE_TESTS" == "1" ]] || return 0
  log "POS Edge deployment and origin metadata"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ supabase functions/secrets list --project-ref %q --output json; verify ACTIVE handlers and exact-origin digest\n' "$POS_PROJECT_REF"
    return 0
  fi
  local function_metadata secret_metadata
  function_metadata="$(mktemp)"; secret_metadata="$(mktemp)"
  supabase functions list --project-ref "$POS_PROJECT_REF" --output json > "$function_metadata" || { rm -f "$function_metadata" "$secret_metadata"; fail "Cannot inspect Edge deployment metadata."; }
  # Some CLI versions include plaintext values. Persist only the selected
  # origin digest; never write API keys or other secret values to a local file.
  if ! supabase secrets list --project-ref "$POS_PROJECT_REF" --output json | python3 -c '
import hashlib,json,re,sys
rows=json.load(sys.stdin)
origin=next((row for row in rows if row.get("name")=="ALLOWED_ORIGINS"),{})
value=origin.get("value","")
digest=origin.get("digest") or (value if re.fullmatch(r"[0-9a-f]{64}",value) else hashlib.sha256(value.encode()).hexdigest())
print(json.dumps({"name":"ALLOWED_ORIGINS","digest":digest}))
' > "$secret_metadata"; then
    rm -f "$function_metadata" "$secret_metadata"; fail "Cannot inspect Edge origin metadata."
  fi
  if ! python3 - "$function_metadata" "$secret_metadata" "$LIVE_URL" <<'PYEDGEMETADATA'
import hashlib,json,sys
from pathlib import Path
functions,origin=[json.loads(Path(p).read_text()) for p in sys.argv[1:3]]
required={'create_staff_user','provision-fixed-pos-account','complete-initial-password-change','sepay-webhook','emergency-fulfillment-dispatcher','public-receipt','direct-order-public','direct-order-notification-dispatcher','direct-order-translation-dispatcher','deliberry-webhook','deliberry-dispatcher','generate-settlement','generate_delivery_settlement'}
active={row.get('slug') for row in functions if row.get('status')=='ACTIVE'}
assert required<=active, 'A required Edge deployment is not ACTIVE'
assert origin.get('digest')==hashlib.sha256(sys.argv[3].encode()).hexdigest(), 'Remote exact-origin digest mismatch'
print('POS Edge metadata: 13 required handlers ACTIVE; remote origin digest matches production (no endpoint probes).')
PYEDGEMETADATA
  then rm -f "$function_metadata" "$secret_metadata"; fail "Edge metadata verification failed."; fi
  rm -f "$function_metadata" "$secret_metadata"
}

verify_deliberry_retirement_readiness() {
  if [[ "$SKIP_SMOKE_TESTS" == "1" ]]; then
    log "Retired endpoint HTTP checks skipped by no-smoke policy"
    return 0
  fi
  log "Deliberry retirement endpoint verification"
  local function_name status response_file
  for function_name in deliberry-webhook deliberry-dispatcher \
    generate-settlement generate_delivery_settlement; do
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '+ POST %s without credentials; require HTTP 410\n' "$function_name"
      continue
    fi
    response_file="$(mktemp)"
    if ! status="$(curl -sS --max-time 30 -o "$response_file" -w '%{http_code}' \
      -X POST "$SUPABASE_URL/functions/v1/$function_name" \
      -H 'Content-Type: application/json' --data '{}')"; then
      rm -f "$response_file"
      fail "Could not verify retired endpoint $function_name."
    fi
    if [[ "$status" != "410" ]] || \
      ! grep -q 'DELIBERRY_INTEGRATION_RETIRED' "$response_file"; then
      rm -f "$response_file"
      fail "Retired endpoint $function_name must return HTTP 410."
    fi
    rm -f "$response_file"
    printf '%s: retired (HTTP 410).\n' "$function_name"
  done
}

verify_emergency_dispatcher_readiness() {
  if [[ "$SKIP_SMOKE_TESTS" == "1" ]]; then
    log "Emergency dispatcher HTTP probe skipped by no-smoke policy"
    return 0
  fi
  log "Emergency fulfilment dispatcher readiness"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ POST emergency-fulfillment-dispatcher without authorization; require HTTP 401\n'
    return 0
  fi

  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "$SUPABASE_URL/functions/v1/emergency-fulfillment-dispatcher" \
    -H 'Content-Type: application/json' \
    --data '{}')" || fail "Could not reach emergency fulfilment dispatcher."
  [[ "$status" == "401" ]] ||
    fail "Emergency fulfilment dispatcher readiness returned HTTP $status instead of 401."
  printf 'Emergency fulfilment dispatcher secrets and auth gate verified.\n'
}

verify_direct_order_dispatcher_readiness() {
  if [[ "$SKIP_SMOKE_TESTS" == "1" ]]; then
    log "Customer notification dispatcher HTTP probe skipped by no-smoke policy"
    return 0
  fi
  log "Direct order customer notification dispatcher readiness"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ POST direct-order-notification-dispatcher without authorization; require HTTP 401\n'
    return 0
  fi
  local status
  status="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST \
    "$SUPABASE_URL/functions/v1/direct-order-notification-dispatcher" \
    -H 'Content-Type: application/json' --data '{}')" ||
    fail "Could not reach direct order customer notification dispatcher."
  [[ "$status" == "401" ]] ||
    fail "Direct order notification dispatcher returned HTTP $status instead of 401."
  printf 'Direct order customer notification dispatcher auth gate verified.\n'
}

verify_remote_allowed_origin() {
  if [[ "$SKIP_SMOKE_TESTS" == "1" ]]; then
    log "Origin OPTIONS probes skipped by no-smoke policy"
    return 0
  fi
  log "POS Edge production origin verification"
  local function_name headers allowed
  for function_name in \
    provision-fixed-pos-account \
    complete-initial-password-change \
    public-receipt \
    direct-order-public; do
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '+ OPTIONS %s with Origin %q; require exact access-control-allow-origin\n' \
        "$function_name" "$LIVE_URL"
      continue
    fi

    headers="$(mktemp)"
    if ! curl -sS -o /dev/null -D "$headers" -X OPTIONS \
      "$SUPABASE_URL/functions/v1/$function_name" \
      -H "Origin: $LIVE_URL" \
      -H "apikey: $SUPABASE_ANON_KEY"; then
      rm -f "$headers"
      fail "Could not verify $function_name Edge origin configuration."
    fi
    allowed="$(awk 'tolower($0) ~ /^access-control-allow-origin:[[:space:]]*/ {
      value=$0
      sub(/^[^:]*:[[:space:]]*/, "", value)
      sub(/\r$/, "", value)
      print value
    }' "$headers" | tail -1)"
    rm -f "$headers"
    [[ "$allowed" == "$LIVE_URL" ]] ||
      fail "Deployed $function_name Edge origin is not exactly $LIVE_URL."
    printf 'Deployed %s Edge origin verified: %s\n' \
      "$function_name" "$allowed"
  done
}

run_login_smoke() {
  if [[ "$SKIP_VERCEL" == "1" ]]; then
    log "Fixed POS account login smoke skipped because Vercel deploy was skipped"
    return 0
  fi
  if [[ "$SKIP_LOGIN_SMOKE" == "1" ]]; then
    log "Fixed POS account login smoke skipped"
    warn "Do not report this deploy as login-ready until a fixed-account login smoke passes."
    return 0
  fi

  log "Fixed POS account login smoke"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ FIXED_SMOKE_ACCOUNT_CODE=<set> FIXED_SMOKE_PASSWORD=<set> bash %q\n' \
      "$FIXED_ACCOUNT_SMOKE_SCRIPT"
    return 0
  fi

  [[ -n "${FIXED_SMOKE_ACCOUNT_CODE:-}" ]] ||
    fail "FIXED_SMOKE_ACCOUNT_CODE is required for post-deploy login smoke."
  [[ -n "${FIXED_SMOKE_PASSWORD:-}" ]] ||
    fail "FIXED_SMOKE_PASSWORD is required for post-deploy login smoke."

  run bash "$FIXED_ACCOUNT_SMOKE_SCRIPT"
}

run_db_only_flow() {
  log "DB-only release scope"
  printf 'Production Auth/account readiness: N/A (not invoked; no login credentials required).\n'
  printf 'Vercel deployment: N/A.\n'
  printf 'Live HTTP check: N/A.\n'
  printf 'Operational login smoke: N/A (not invoked).\n'
  warn "DB-only releases do not establish or claim POS login readiness."

  load_env
  reject_target_overrides
  run_checks
  apply_migration

  log "DB-only release flow completed"
  printf 'Database migration gates finished; Auth, Vercel, live HTTP, and login readiness remain N/A.\n'
}

main() {
  parse_args "$@"
  validate_db_only_options
  cd "$ROOT_DIR"
  confirm_production
  preflight
  if [[ "$DB_ONLY" == "1" ]]; then
    run_db_only_flow
    return 0
  fi
  if [[ "$ROLLBACK_HIERARCHY" == "1" ]]; then
    rollback_hierarchy
    log "Rollback flow completed"
    return 0
  fi
  load_env
  ensure_flutter_env
  verify_allowed_production_origins
  verify_vercel_firebase_web_env
  run_auth_check
  run_checks
  verify_sepay_alert_secrets
  run python3 "$ROOT_DIR/scripts/sync_direct_order_translation_schedule_secret.py"
  verify_direct_order_secrets
  # Deploy the compatibility-capable self-service endpoint before replacing the
  # predecessor password trigger. If the DB gate fails, the endpoint remains
  # safe against the predecessor schema; the web app is deployed only after the
  # fail-closed migration and verification succeed.
  deploy_pos_edge_functions
  verify_no_smoke_edge_metadata
  verify_deliberry_retirement_readiness
  verify_remote_allowed_origin
  verify_emergency_dispatcher_readiness
  verify_direct_order_dispatcher_readiness
  apply_migration
  local_flutter_build
  deploy_vercel
  run_login_smoke

  log "Deployment flow completed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
