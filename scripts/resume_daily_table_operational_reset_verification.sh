#!/usr/bin/env bash
set -euo pipefail

# Resume only the post-commit verification/history stages of the existing
# production runner. No schema apply or Auth/account operation is repeated.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy_pos_production.sh"

if [[ "${1:-}" == "--yes" ]]; then YES=1; shift; fi
[[ $# == 0 ]] || fail "Usage: scripts/resume_daily_table_operational_reset_verification.sh [--yes]"
DB_ONLY=1
MIGRATION_FILE="supabase/migrations/20261001020000_daily_table_operational_reset.sql"
MIGRATION_OPTION_SET=1
TEST_TARGETS="test/operational_day_service_test.dart test/offline_mutation_queue_service_test.dart"
validate_db_only_options
cd "$ROOT_DIR"
confirm_production
preflight
load_env
reject_target_overrides
run_checks
resolve_production_migration_gate "$ROOT_DIR/$MIGRATION_FILE"

log "Resume committed daily reset verification"
run_linked_psql_file "$PRODUCTION_MIGRATION_VERIFY" "daily reset post-commit verification"
if ! migration_history_contains_remote_version "$PRODUCTION_MIGRATION_VERSION"; then
  log "Register verified daily reset migration"
  run supabase migration repair "$PRODUCTION_MIGRATION_VERSION" --status applied --yes
fi
require_migration_history_present "$PRODUCTION_MIGRATION_VERSION"
log "Daily reset verification and migration history completed"
