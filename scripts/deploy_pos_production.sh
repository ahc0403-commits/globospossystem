#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"

EXPECTED_PROJECT_REF="${EXPECTED_PROJECT_REF:-ynriuoomotxuwhuxxmhj}"
EXPECTED_VERCEL_PROJECT="${EXPECTED_VERCEL_PROJECT:-globospossystem}"
LIVE_URL="${LIVE_URL:-https://globospossystem.vercel.app}"
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
SKIP_REPAIR="${SKIP_REPAIR:-0}"
REQUIRE_CLEAN_GIT="${REQUIRE_CLEAN_GIT:-0}"

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy_pos_production.sh [options]

Default flow:
  preflight -> pilot Auth readiness -> dart analyze -> focused tests ->
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
  --skip-repair      Do not mark the migration version as applied.
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
  SUPABASE_DB_URL=postgresql://...
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
    "$EXPECTED_PROJECT_REF" "$EXPECTED_VERCEL_PROJECT"
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
      --skip-repair)
        SKIP_REPAIR=1
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
  [[ "$DEPLOY_MODE" == "prebuilt" || "$DEPLOY_MODE" == "remote" ]] ||
    fail "DEPLOY_MODE must be prebuilt or remote"

  [[ -f "$PROJECT_REF_FILE" ]] || fail "Missing project ref file: $PROJECT_REF_FILE"
  local project_ref
  project_ref="$(tr -d '\r\n' < "$PROJECT_REF_FILE")"
  printf 'Supabase linked project: %s\n' "$project_ref"
  if [[ "$project_ref" != "$EXPECTED_PROJECT_REF" && "${ALLOW_PROJECT_REF_MISMATCH:-0}" != "1" ]]; then
    fail "Linked Supabase project is not production ($EXPECTED_PROJECT_REF)."
  fi

  [[ -f "$ROOT_DIR/.vercel/project.json" ]] ||
    fail "Missing .vercel/project.json. Run vercel link before deploying."
  if ! grep -q "\"projectName\": \"$EXPECTED_VERCEL_PROJECT\"" "$ROOT_DIR/.vercel/project.json"; then
    fail "Vercel project is not $EXPECTED_VERCEL_PROJECT."
  fi
  printf 'Vercel project: %s\n' "$EXPECTED_VERCEL_PROJECT"

  local dirty_count
  dirty_count="$(git -C "$ROOT_DIR" status --porcelain | wc -l | tr -d ' ')"
  if [[ "$dirty_count" != "0" ]]; then
    warn "Git worktree has $dirty_count uncommitted paths."
    [[ "$REQUIRE_CLEAN_GIT" != "1" ]] || fail "Refusing to deploy dirty worktree."
  fi

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
  if [[ "$SKIP_DB" != "1" && -n "$MIGRATION_FILE" ]]; then
    need_cmd supabase
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
    --expected-project-ref "$EXPECTED_PROJECT_REF"
}

run_checks() {
  if [[ "$SKIP_CHECKS" == "1" ]]; then
    log "Checks skipped"
    return 0
  fi

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

supabase_query_file() {
  local file="$1"
  local output="${2:-table}"
  printf '+ supabase db query <masked-db-url-or-linked> -f %q -o %q\n' "$file" "$output"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  if [[ -n "${SUPABASE_DB_URL:-}" ]]; then
    supabase db query --db-url "$SUPABASE_DB_URL" -f "$file" -o "$output"
  else
    supabase db query --linked -f "$file" -o "$output"
  fi
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
  migration_name="$(basename "$migration_path")"
  migration_version="${migration_name%%_*}"
  [[ "$migration_version" =~ ^[0-9]+$ ]] ||
    fail "Migration file must start with a numeric version: $migration_name"

  log "Apply Supabase migration"
  supabase_query_file "$migration_path" table

  if [[ "$SKIP_REPAIR" == "1" ]]; then
    warn "Migration repair skipped for $migration_version."
    return 0
  fi

  log "Repair Supabase migration history"
  run supabase migration repair "$migration_version" --status applied --yes

  log "Verify migration history"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ supabase migration list | grep %q\n' "$migration_version"
    return 0
  fi
  if supabase migration list 2>/dev/null | grep -Eq "$migration_version[[:space:]]*\\|[[:space:]]*$migration_version"; then
    printf 'Migration history contains local/remote version %s.\n' "$migration_version"
  else
    warn "Could not confirm migration history for $migration_version. Check 'supabase migration list'."
  fi
}

ensure_flutter_env() {
  load_env
  [[ -n "${SUPABASE_URL:-}" ]] || fail "SUPABASE_URL is not set."
  [[ -n "${SUPABASE_ANON_KEY:-}" ]] || fail "SUPABASE_ANON_KEY is not set."

  local normalized_url
  local expected_url
  normalized_url="${SUPABASE_URL%/}"
  expected_url="https://$EXPECTED_PROJECT_REF.supabase.co"
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
      "$PILOT_LOGIN_SMOKE_SCRIPT" "$EXPECTED_PROJECT_REF"
    return 0
  fi

  [[ -n "${PILOT_SMOKE_EMAIL:-}" ]] ||
    fail "PILOT_SMOKE_EMAIL is required for post-deploy pilot login smoke."
  [[ -n "${PILOT_SMOKE_PASSWORD:-}" ]] ||
    fail "PILOT_SMOKE_PASSWORD is required for post-deploy pilot login smoke."

  run bash "$PILOT_LOGIN_SMOKE_SCRIPT" \
    --email "$PILOT_SMOKE_EMAIL" \
    --expected-project-ref "$EXPECTED_PROJECT_REF"
}

main() {
  parse_args "$@"
  cd "$ROOT_DIR"
  confirm_production
  preflight
  run_auth_check
  run_checks
  apply_migration
  local_flutter_build
  deploy_vercel
  run_login_smoke

  log "Deployment flow completed"
}

main "$@"
