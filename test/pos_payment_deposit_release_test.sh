#!/usr/bin/env bash
set -euo pipefail

RELEASE_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$RELEASE_TEST_TMP"' EXIT
export RELEASE_TEST_LOG="$RELEASE_TEST_TMP/calls"

# Offline flow rehearsal: all operational functions are replaced by local spies.
simulate_release() {
  bash -c '
    source "$1/scripts/deploy_pos_production.sh"
    shift
    record() {
      printf "%s\n" "$1" >>"$RELEASE_TEST_LOG"
      [[ "${RELEASE_TEST_FAIL_PHASE:-}" != "$1" ]] || return 47
    }
    confirm_production() { record confirm; }
    preflight() { record clean; record fresh-main; record exact-sha-local; }
    load_env() {
      record env
      if [[ "${RELEASE_TEST_SKIP_AUTH_ENV:-0}" == 1 ]]; then SKIP_AUTH_CHECK=1; fi
    }
    ensure_flutter_env() { record client-config; }
    verify_allowed_production_origins() { record origin; }
    verify_vercel_firebase_web_env() { record firebase; }
    run_auth_check() { record auth; }
    run_checks() { record checks; }
    verify_sepay_alert_secrets() { record sepay; }
    run() { record translation-schedule; }
    verify_no_smoke_edge_metadata() { record edge-metadata; }
    verify_direct_order_secrets() { record direct-secrets; }
    deploy_pos_edge_functions() { record edge-deploy; }
    verify_deliberry_retirement_readiness() { record retirement; }
    verify_remote_allowed_origin() { record edge-origin; }
    verify_emergency_dispatcher_readiness() { record emergency; }
    verify_direct_order_dispatcher_readiness() { record direct-ready; }
    apply_migration() { record db-apply; }
    local_flutter_build() { record build; }
    deploy_vercel() { record web-deploy; }
    run_login_smoke() { if [[ "$SKIP_LOGIN_SMOKE" == 1 ]]; then record login-not-run; else record login; fi; }
    main "$@"
  ' release-test "$RELEASE_TEST_ROOT" "$@"
}

: >"$RELEASE_TEST_LOG"
simulate_release --web-only --dry-run --yes >"$RELEASE_TEST_TMP/web-output"
cat >"$RELEASE_TEST_TMP/expected-web" <<'EOF'
confirm
clean
fresh-main
exact-sha-local
env
client-config
origin
firebase
auth
checks
build
web-deploy
login
EOF
cmp "$RELEASE_TEST_LOG" "$RELEASE_TEST_TMP/expected-web"
grep -Fq 'Mobile web uses the same POS web release' "$RELEASE_TEST_TMP/web-output"

: >"$RELEASE_TEST_LOG"
simulate_release --dry-run --yes >/dev/null
grep -qx edge-deploy "$RELEASE_TEST_LOG"
grep -qx db-apply "$RELEASE_TEST_LOG"
python3 - "$RELEASE_TEST_LOG" <<'PY'
import sys
steps=open(sys.argv[1]).read().splitlines()
assert steps.index('checks') < steps.index('edge-deploy') < steps.index('db-apply') < steps.index('web-deploy') < steps.index('login')
PY

for phase in clean fresh-main exact-sha-local auth checks; do
  : >"$RELEASE_TEST_LOG"
  if RELEASE_TEST_FAIL_PHASE="$phase" simulate_release --web-only --yes >"$RELEASE_TEST_TMP/failure" 2>&1; then
    printf 'ERROR: Failed gate allowed a release: %s\n' "$phase" >&2
    exit 1
  fi
  ! grep -qx web-deploy "$RELEASE_TEST_LOG"
done

: >"$RELEASE_TEST_LOG"
simulate_release --web-only --skip-login-smoke --yes >"$RELEASE_TEST_TMP/login-opt-out"
grep -qx login-not-run "$RELEASE_TEST_LOG"
! grep -qx login "$RELEASE_TEST_LOG"
for phase in clean fresh-main exact-sha-local auth checks build web-deploy; do
  grep -qx "$phase" "$RELEASE_TEST_LOG"
done

# The cloud path honors only an explicit owner waiver of assigned-account
# login. Every other release gate and the HTTP path remain enabled.
: >"$RELEASE_TEST_LOG"
simulate_release --supabase-backend mcp --web-only --skip-login-smoke --yes \
  >"$RELEASE_TEST_TMP/cloud-login-opt-out"
grep -qx login-not-run "$RELEASE_TEST_LOG"
for phase in clean fresh-main exact-sha-local auth checks build web-deploy; do
  grep -qx "$phase" "$RELEASE_TEST_LOG"
done
! grep -Eq '^(edge-deploy|db-apply|login)$' "$RELEASE_TEST_LOG"
for phase in clean fresh-main exact-sha-local auth checks build; do
  : >"$RELEASE_TEST_LOG"
  if RELEASE_TEST_FAIL_PHASE="$phase" simulate_release --supabase-backend mcp \
    --web-only --skip-login-smoke --yes >"$RELEASE_TEST_TMP/rejected" 2>&1; then
    printf 'ERROR: Cloud waiver ignored failed gate: %s\n' "$phase" >&2
    exit 1
  fi
  ! grep -qx web-deploy "$RELEASE_TEST_LOG"
done
: >"$RELEASE_TEST_LOG"
if SKIP_LOGIN_SMOKE=1 simulate_release --supabase-backend mcp --web-only --yes \
  >"$RELEASE_TEST_TMP/rejected" 2>&1; then exit 1; fi
[[ ! -s "$RELEASE_TEST_LOG" ]]
: >"$RELEASE_TEST_LOG"
if simulate_release --supabase-backend mcp --db-only --skip-login-smoke \
  --migration supabase/migrations/20261028053422_procurement_manager_adjustment.sql \
  --yes >"$RELEASE_TEST_TMP/rejected" 2>&1; then exit 1; fi
[[ ! -s "$RELEASE_TEST_LOG" ]]
for option in --skip-checks --no-tests --skip-auth-check --skip-smoke-tests \
  --skip-db --skip-build --skip-vercel; do
  : >"$RELEASE_TEST_LOG"
  if simulate_release --supabase-backend mcp --web-only --skip-login-smoke \
    "$option" --yes >"$RELEASE_TEST_TMP/rejected" 2>&1; then
    printf 'ERROR: Cloud waiver skipped another gate: %s\n' "$option" >&2
    exit 1
  fi
  [[ ! -s "$RELEASE_TEST_LOG" ]]
done

check_cloud_login_precondition() {
  env -u FIXED_SMOKE_ACCOUNT_CODE -u FIXED_SMOKE_PASSWORD bash -c '
    source "$1/scripts/deploy_pos_production.sh"; shift
    parse_args --supabase-backend mcp --web-only "$@"
    validate_cloud_options; validate_web_only_options
    reject_target_overrides() { :; }
    need_cmd() { printf "LOGIN_PRECONDITION_PASSED\n"; exit 42; }
    preflight
  ' cloud-login-precondition "$RELEASE_TEST_ROOT" "$@"
}
if check_cloud_login_precondition >"$RELEASE_TEST_TMP/required-login" 2>&1; then exit 1; fi
grep -Fq 'securely supplied fixed-account login smoke credentials' "$RELEASE_TEST_TMP/required-login"
! grep -q LOGIN_PRECONDITION_PASSED "$RELEASE_TEST_TMP/required-login"
waiver_status=0
check_cloud_login_precondition --skip-login-smoke \
  >"$RELEASE_TEST_TMP/waived-login" 2>&1 || waiver_status=$?
[[ "$waiver_status" == 42 ]]
grep -q LOGIN_PRECONDITION_PASSED "$RELEASE_TEST_TMP/waived-login"
env -u FIXED_SMOKE_ACCOUNT_CODE -u FIXED_SMOKE_PASSWORD bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  parse_args --supabase-backend mcp --web-only --skip-login-smoke
  validate_cloud_options; validate_web_only_options
  run_login_smoke
' cloud-login-evidence "$RELEASE_TEST_ROOT" >"$RELEASE_TEST_TMP/login-evidence" 2>&1
grep -Fq 'LOGIN_SMOKE=NOT_RUN_OWNER_WAIVER' "$RELEASE_TEST_TMP/login-evidence"
! grep -qx 'PASS' "$RELEASE_TEST_TMP/login-evidence"

: >"$RELEASE_TEST_LOG"
if SKIP_LOGIN_SMOKE=1 simulate_release --web-only --yes >"$RELEASE_TEST_TMP/rejected" 2>&1; then exit 1; fi
[[ ! -s "$RELEASE_TEST_LOG" ]]

for option in --db-only --skip-checks --no-tests --skip-auth-check \
  --skip-smoke-tests --skip-db --skip-build --skip-vercel --rollback-hierarchy; do
  : >"$RELEASE_TEST_LOG"
  if simulate_release --web-only "$option" --yes >"$RELEASE_TEST_TMP/rejected" 2>&1; then
    printf 'ERROR: Incompatible option accepted: %s\n' "$option" >&2
    exit 1
  fi
  [[ ! -s "$RELEASE_TEST_LOG" ]]
done
if simulate_release --web-only --migration other.sql --yes >"$RELEASE_TEST_TMP/rejected" 2>&1; then exit 1; fi
if MIGRATION_FILE=other.sql simulate_release --web-only --yes >"$RELEASE_TEST_TMP/rejected" 2>&1; then exit 1; fi
: >"$RELEASE_TEST_LOG"
if RELEASE_TEST_SKIP_AUTH_ENV=1 simulate_release --web-only --yes >"$RELEASE_TEST_TMP/rejected" 2>&1; then exit 1; fi
! grep -qx web-deploy "$RELEASE_TEST_LOG"

# Test the fixed two-migration wrapper in a synthetic local checkout.
fixture="$RELEASE_TEST_TMP/fixture"
mkdir -p "$fixture/scripts"
cp "$RELEASE_TEST_ROOT/scripts/release_payment_qr_deposit.sh" "$fixture/scripts/"
cat >"$fixture/scripts/deploy_pos_production.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$RELEASE_TEST_LOG"
if [[ "${RELEASE_TEST_FAIL_PHASE:-}" == deposit && "$*" == *deposit_breakdown* ]]; then exit 48; fi
EOF
git init --quiet --initial-branch=main "$fixture"
git -C "$fixture" config user.name 'Local Release Test'
git -C "$fixture" config user.email local-release@example.invalid
git -C "$fixture" add scripts
git -C "$fixture" commit --quiet -m 'local release fixture'
fixture_sha="$(git -C "$fixture" rev-parse HEAD)"
: >"$RELEASE_TEST_LOG"
bash "$fixture/scripts/release_payment_qr_deposit.sh" --sha "$fixture_sha" >/dev/null
python3 - "$RELEASE_TEST_LOG" <<'PY'
import sys
steps=open(sys.argv[1]).read().splitlines()
assert len(steps)==3
assert '--db-only' in steps[0] and '20261012183000_receipt_collection_bank.sql' in steps[0]
assert '--db-only' in steps[1] and '20261012210000_deposit_breakdown.sql' in steps[1]
assert steps[2]=='--web-only --mode prebuilt --dry-run'
assert all('--dry-run' in line for line in steps)
PY
: >"$RELEASE_TEST_LOG"
bash "$fixture/scripts/release_payment_qr_deposit.sh" --sha "$fixture_sha" --stage web --execute >/dev/null
[[ "$(cat "$RELEASE_TEST_LOG")" == '--web-only --mode prebuilt --yes' ]]
: >"$RELEASE_TEST_LOG"
if RELEASE_TEST_FAIL_PHASE=deposit bash "$fixture/scripts/release_payment_qr_deposit.sh" --sha "$fixture_sha" --execute >"$RELEASE_TEST_TMP/failure" 2>&1; then exit 1; fi
[[ "$(wc -l <"$RELEASE_TEST_LOG" | tr -d ' ')" == 2 ]]
! grep -q -- --web-only "$RELEASE_TEST_LOG"
: >"$RELEASE_TEST_LOG"
if bash "$fixture/scripts/release_payment_qr_deposit.sh" --sha 0000000000000000000000000000000000000000 >"$RELEASE_TEST_TMP/failure" 2>&1; then exit 1; fi
[[ ! -s "$RELEASE_TEST_LOG" ]]
printf 'user change\n' >"$fixture/unrelated.txt"
if bash "$fixture/scripts/release_payment_qr_deposit.sh" --sha "$fixture_sha" --execute >"$RELEASE_TEST_TMP/failure" 2>&1; then exit 1; fi
[[ ! -s "$RELEASE_TEST_LOG" ]]
printf 'PASS: web/mobile-web scope, required gates, default flow, exact migrations, dry-run, stop-on-failure and source guards (offline).\n'
