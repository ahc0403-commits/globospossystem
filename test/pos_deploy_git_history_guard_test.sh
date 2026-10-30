#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="$ROOT_DIR/scripts/deploy_pos_production.sh"
TMP_DIR="$(mktemp -d)"
ORIGIN_REPO="$TMP_DIR/origin.git"
SEED_REPO="$TMP_DIR/seed"
STALE_REPO="$TMP_DIR/stale"
APPROVED_REPO="$TMP_DIR/approved"
FAKE_BIN="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

git init --bare --initial-branch=main "$ORIGIN_REPO" >/dev/null
git init --initial-branch=main "$SEED_REPO" >/dev/null
git -C "$SEED_REPO" config user.email deploy-test@globos.test
git -C "$SEED_REPO" config user.name 'Deploy Test'
mkdir -p "$SEED_REPO/scripts"
cp "$DEPLOY_SCRIPT" "$SEED_REPO/scripts/deploy_pos_production.sh"
mkdir -p "$SEED_REPO/scripts/lib"
cp "$ROOT_DIR/scripts/lib/production_migration_gate.sh" "$SEED_REPO/scripts/lib/"
git -C "$SEED_REPO" add scripts/deploy_pos_production.sh scripts/lib/production_migration_gate.sh
git -C "$SEED_REPO" commit -m 'fixture baseline' >/dev/null
git -C "$SEED_REPO" remote add origin "$ORIGIN_REPO"
git -C "$SEED_REPO" push --set-upstream origin main >/dev/null

git clone --quiet "$ORIGIN_REPO" "$STALE_REPO"
git -C "$STALE_REPO" config user.email deploy-test@globos.test
git -C "$STALE_REPO" config user.name 'Deploy Test'
git -C "$STALE_REPO" switch -c feature >/dev/null
printf 'feature\n' >"$STALE_REPO/feature.txt"
git -C "$STALE_REPO" add feature.txt
git -C "$STALE_REPO" commit -m 'fixture feature' >/dev/null

printf 'fresh main\n' >"$SEED_REPO/main.txt"
git -C "$SEED_REPO" add main.txt
git -C "$SEED_REPO" commit -m 'advance main' >/dev/null
git -C "$SEED_REPO" push origin main >/dev/null

git clone --quiet "$ORIGIN_REPO" "$APPROVED_REPO"

bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  parse_args --skip-smoke-tests
  DRY_RUN=0
  SKIP_VERCEL=0
  SKIP_DB=1
  enforce_origin_main_ancestry
' guard "$APPROVED_REPO" >/dev/null

set +e
stale_output="$(ALLOW_GIT_ANCESTRY_MISMATCH=1 bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  parse_args --skip-smoke-tests
  DRY_RUN=0
  SKIP_VERCEL=0
  SKIP_DB=1
  enforce_origin_main_ancestry
' guard "$STALE_REPO" 2>&1)"
stale_status=$?
set -e
[[ "$stale_status" -ne 0 ]]
[[ "$stale_output" == *'Production deployment requires exact HEAD == freshly fetched origin/main'* ]]
git -C "$STALE_REPO" rev-parse origin/main | grep -qx \
  "$(git -C "$SEED_REPO" rev-parse HEAD)"

set +e
stale_dry_run_output="$(bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  parse_args --skip-smoke-tests
  DRY_RUN=1
  REQUIRE_CLEAN_GIT=0
  SKIP_VERCEL=0
  SKIP_DB=1
  enforce_origin_main_ancestry
' guard "$STALE_REPO" 2>&1)"
stale_dry_run_status=$?
set -e
[[ "$stale_dry_run_status" -ne 0 ]]
[[ "$stale_dry_run_output" == *'Production deployment requires exact HEAD == freshly fetched origin/main'* ]]

bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  parse_args --skip-smoke-tests
  DRY_RUN=0
  REQUIRE_CLEAN_GIT=1
  enforce_clean_git
' guard "$APPROVED_REPO" >/dev/null

printf 'dirty\n' >"$APPROVED_REPO/dirty.txt"
set +e
dirty_output="$(bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  parse_args --skip-smoke-tests
  DRY_RUN=0
  REQUIRE_CLEAN_GIT=1
  enforce_clean_git
' guard "$APPROVED_REPO" 2>&1)"
dirty_status=$?
set -e
[[ "$dirty_status" -ne 0 ]]
[[ "$dirty_output" == *'Refusing to deploy dirty worktree'* ]]

set +e
unsafe_exception_output="$(bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  parse_args --skip-smoke-tests
  DRY_RUN=0
  REQUIRE_CLEAN_GIT=0
  enforce_clean_git
' guard "$APPROVED_REPO" 2>&1)"
unsafe_exception_status=$?
set -e
[[ "$unsafe_exception_status" -ne 0 ]]
[[ "$unsafe_exception_output" == *'allowed only for an explicit --dry-run'* ]]

bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  parse_args --skip-smoke-tests
  DRY_RUN=1
  REQUIRE_CLEAN_GIT=0
  enforce_clean_git
' guard "$APPROVED_REPO" >/dev/null 2>&1

rm "$APPROVED_REPO/dirty.txt"

# A fixture verifier exercises the official invocation boundary, not real checks.
# Real evidence integrity and process-output behavior is covered by Python tests.
cat >"$APPROVED_REPO/scripts/pos_local_release_gate.py" <<'PYFIXTURE'
import os,sys
from pathlib import Path
assert sys.argv[1:4] == ['run','--kind','exact-main']
assert sys.argv[4] == '--output' and sys.argv[6:] == ['--profile', 'production-checks']
assert not Path(sys.argv[5]).exists()
if os.environ['LOCAL_VERIFIER_FIXTURE_MODE'] == 'fail':
    raise SystemExit(42)
Path(sys.argv[5]).mkdir()
Path(sys.argv[5], 'receipt.json').write_text('fixture only')
PYFIXTURE
git -C "$APPROVED_REPO" add scripts/pos_local_release_gate.py
git -C "$APPROVED_REPO" -c user.name='Deploy Test' -c user.email=deploy-test@globos.test commit --quiet -m 'local verifier fixture'
git -C "$APPROVED_REPO" push origin main >/dev/null

mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf 'GitHub test lookup must not be invoked\n' >&2
exit 99
EOF
chmod +x "$FAKE_BIN/gh"
PATH="$FAKE_BIN:$PATH" TMPDIR="$TMP_DIR" LOCAL_VERIFIER_FIXTURE_MODE=success bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  parse_args --skip-smoke-tests --skip-checks --no-tests
  enforce_local_release_contract
' guard "$APPROVED_REPO" >/dev/null

set +e
local_output="$(PATH="$FAKE_BIN:$PATH" TMPDIR="$TMP_DIR" LOCAL_VERIFIER_FIXTURE_MODE=fail bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  parse_args --skip-smoke-tests --skip-checks --no-tests
  enforce_local_release_contract
' guard "$APPROVED_REPO" 2>&1)"
local_status=$?
set -e
[[ "$local_status" -ne 0 ]]
[[ "$local_output" == *'Required local release verification failed'* ]]

rm "$APPROVED_REPO/scripts/pos_local_release_gate.py"
set +e
missing_output="$(PATH="$FAKE_BIN:$PATH" bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  enforce_local_release_contract
' guard "$APPROVED_REPO" 2>&1)"
missing_status=$?
set -e
[[ "$missing_status" -ne 0 ]]
[[ "$missing_output" == *'Missing trusted local release verifier'* ]]

cat >"$FAKE_BIN/supabase" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'migration list' ]] || exit 90
case "${MIGRATION_LIST_MODE:?}" in
  present)
    printf ' LOCAL          | REMOTE         | TIME\n'
    printf ' 20260711090000 | 20260711090000 | 2026-07-11\n'
    ;;
  absent)
    printf ' LOCAL          | REMOTE | TIME\n'
    printf ' 20260711090000 |        |\n'
    ;;
  fail)
    exit 42
    ;;
esac
EOF
chmod +x "$FAKE_BIN/supabase"

PATH="$FAKE_BIN:$PATH" MIGRATION_LIST_MODE=absent bash -c '
  source "$1"
  require_migration_history_absent 20260711090000
' history "$DEPLOY_SCRIPT" >/dev/null
PATH="$FAKE_BIN:$PATH" MIGRATION_LIST_MODE=present bash -c '
  source "$1"
  require_migration_history_present 20260711090000
' history "$DEPLOY_SCRIPT" >/dev/null

for assertion in absent present; do
  mismatch_mode=present
  [[ "$assertion" == absent ]] || mismatch_mode=absent
  set +e
  mismatch_output="$(PATH="$FAKE_BIN:$PATH" MIGRATION_LIST_MODE="$mismatch_mode" \
    bash -c 'source "$1"; "require_migration_history_$2" 20260711090000' \
    history "$DEPLOY_SCRIPT" "$assertion" 2>&1)"
  mismatch_status=$?
  set -e
  [[ "$mismatch_status" -ne 0 ]]
  [[ "$mismatch_output" == *'Remote migration history'* ]]

  set +e
  list_failure_output="$(PATH="$FAKE_BIN:$PATH" MIGRATION_LIST_MODE=fail \
    bash -c 'source "$1"; "require_migration_history_$2" 20260711090000' \
    history "$DEPLOY_SCRIPT" "$assertion" 2>&1)"
  list_failure_status=$?
  set -e
  [[ "$list_failure_status" -ne 0 ]]
  [[ "$list_failure_output" == *'Could not list Supabase migration history'* ]]
done

printf 'PASS: production Git provenance and migration history guards\n'
