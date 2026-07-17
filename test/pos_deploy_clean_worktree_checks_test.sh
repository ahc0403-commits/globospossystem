#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="$ROOT_DIR/scripts/deploy_pos_production.sh"
TMP_DIR="$(mktemp -d)"
REHEARSAL_REPO="$TMP_DIR/rehearsal"
FAKE_BIN="$TMP_DIR/bin"
CALL_LOG="$TMP_DIR/calls.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$REHEARSAL_REPO/scripts" "$REHEARSAL_REPO/test" "$FAKE_BIN"
cp "$DEPLOY_SCRIPT" "$REHEARSAL_REPO/scripts/deploy_pos_production.sh"
mkdir -p "$REHEARSAL_REPO/supabase/migrations"
cp "$ROOT_DIR/supabase/migrations/20260717090000_store_opening_setup_wizard.sql" \
  "$REHEARSAL_REPO/supabase/migrations/"
for store_setup_sql in \
  preflight_store_opening_setup_wizard.sql \
  apply_store_opening_setup_wizard.sql \
  verify_store_opening_setup_wizard.sql \
  rollback_store_opening_setup_wizard.sql; do
  cp "$ROOT_DIR/scripts/$store_setup_sql" "$REHEARSAL_REPO/scripts/"
done
printf 'name: deploy_rehearsal\nenvironment:\n  sdk: ^3.8.0\n' >"$REHEARSAL_REPO/pubspec.yaml"
printf '{"packages":[]}\n' >"$REHEARSAL_REPO/pubspec.lock"
printf 'void main() {}\n' >"$REHEARSAL_REPO/test/focused_test.dart"
printf '.dart_tool/\n' >"$REHEARSAL_REPO/.gitignore"

git init --quiet --initial-branch=main "$REHEARSAL_REPO"
git -C "$REHEARSAL_REPO" config user.email deploy-test@globos.test
git -C "$REHEARSAL_REPO" config user.name 'Deploy Test'
git -C "$REHEARSAL_REPO" add .
git -C "$REHEARSAL_REPO" commit --quiet -m 'clean rehearsal fixture'

cat >"$FAKE_BIN/flutter" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'flutter %s\n' "$*" >>"$CALL_LOG"
if [[ "$*" == 'pub get --enforce-lockfile' ]]; then
  [[ "${FAIL_PUB_GET:-0}" != "1" ]] || exit 42
  mkdir -p .dart_tool
  printf '{"configVersion":2,"packages":[]}\n' >.dart_tool/package_config.json
  exit 0
fi
if [[ "${1:-}" == 'test' ]]; then
  [[ -f .dart_tool/package_config.json ]] || exit 43
  exit 0
fi
exit 44
EOF

cat >"$FAKE_BIN/dart" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'dart %s\n' "$*" >>"$CALL_LOG"
[[ "$*" == 'analyze' ]] || exit 45
[[ -f .dart_tool/package_config.json ]] || exit 46
EOF

chmod +x "$FAKE_BIN/flutter" "$FAKE_BIN/dart"
export PATH="$FAKE_BIN:$PATH" CALL_LOG

bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  SKIP_CHECKS=0
  DRY_RUN=0
  TEST_TARGETS="test/focused_test.dart"
  cd "$1"
  run_checks
' rehearsal "$REHEARSAL_REPO" >/dev/null

cat >"$TMP_DIR/expected.log" <<'EOF'
flutter pub get --enforce-lockfile
dart analyze
flutter test test/focused_test.dart
EOF
cmp "$TMP_DIR/expected.log" "$CALL_LOG"
[[ -z "$(git -C "$REHEARSAL_REPO" status --porcelain)" ]]

rm -rf "$REHEARSAL_REPO/.dart_tool"
: >"$CALL_LOG"
set +e
failure_output="$(FAIL_PUB_GET=1 bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  SKIP_CHECKS=0
  DRY_RUN=0
  TEST_TARGETS="test/focused_test.dart"
  cd "$1"
  run_checks
' rehearsal "$REHEARSAL_REPO" 2>&1)"
failure_status=$?
set -e

[[ "$failure_status" -eq 42 ]]
[[ "$failure_output" == *'Flutter dependency bootstrap'* ]]
[[ "$(cat "$CALL_LOG")" == 'flutter pub get --enforce-lockfile' ]]
[[ -z "$(git -C "$REHEARSAL_REPO" status --porcelain)" ]]

store_setup_output="$(bash -c '
  source "$1/scripts/deploy_pos_production.sh"
  SKIP_DB=0
  DRY_RUN=1
  MIGRATION_FILE="$1/supabase/migrations/20260717090000_store_opening_setup_wizard.sql"
  cd "$1"
  apply_migration
' rehearsal "$REHEARSAL_REPO")"

[[ "$store_setup_output" == *'Store opening setup rollback readiness'* ]]
[[ "$store_setup_output" == *'Rollback ready (not executed):'*'rollback_store_opening_setup_wizard.sql'* ]]
[[ "$store_setup_output" == *'Confirm migration history absence'* ]]
[[ "$store_setup_output" == *'Store opening setup migration preflight'* ]]
[[ "$store_setup_output" == *'preflight_store_opening_setup_wizard.sql'* ]]
[[ "$store_setup_output" == *'Apply Store opening setup migration atomically'* ]]
[[ "$store_setup_output" == *'apply_store_opening_setup_wizard.sql'* ]]
[[ "$store_setup_output" == *'Store opening setup migration verification'* ]]
[[ "$store_setup_output" == *'verify_store_opening_setup_wizard.sql'* ]]
[[ "$store_setup_output" == *'supabase migration repair 20260717090000 --status applied --yes'* ]]
[[ "$store_setup_output" == *'Confirm migration history presence'* ]]

printf 'PASS: production checks bootstrap clean worktrees and dry-run guarded store setup phases\n'
