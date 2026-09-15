#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

retired_paths=(
  .github/workflows/photo_objet_release_proof.yml
  .github/workflows/photo_objet_sales_backfill.yml
  .github/workflows/photo_objet_sales_collect.yml
  .github/workflows/photo_objet_sales_collect_backup.yml
  .github/workflows/photo_objet_sales_collect_recovery.yml
  .github/workflows/photo_objet_sales_collect_runner.yml
  .github/workflows/photo_objet_sales_contract.yml
  .github/workflows/photo_objet_sales_finalize.yml
  .github/workflows/photo_objet_sales_health.yml
  scripts/photo_objet_slot_health.js
  scripts/pull_moers_sales.js
  scripts/verify_photo_objet_release.js
  scripts/apply_photo_objet_expected_slot_ledger.sql
  scripts/configure_photo_objet_monitoring_policies.sql
  scripts/preflight_photo_objet_collection_2200.sql
  scripts/verify_photo_objet_collection_2200.sql
  scripts/rollback_photo_objet_collection_2200.sql
  scripts/preflight_photo_objet_expected_slot_ledger.sql
  scripts/verify_photo_objet_expected_slot_ledger.sql
  scripts/rollback_photo_objet_expected_slot_ledger.sql
  scripts/preflight_photo_objet_automatic_slot_recovery.sql
  scripts/verify_photo_objet_automatic_slot_recovery.sql
  scripts/rollback_photo_objet_automatic_slot_recovery.sql
  scripts/preflight_photo_objet_precise_start_report_ready.sql
  scripts/verify_photo_objet_precise_start_report_ready.sql
  scripts/rollback_photo_objet_precise_start_report_ready.sql
  test/photo_objet_expected_slot_ledger_test.sh
  test/photo_objet_immutable_health_sql_test.sh
  test/photo_objet_interval_rebuild_test.sh
  test/photo_objet_backup_control_plane_security_test.sh
  docs/MEINVOICE_IMPLEMENTATION_HANDOFF_2026_06_30.md
  docs/pos/GITHUB_MAINTENANCE_GUARDRAILS_V1_IMPLEMENTATION_PLAN_2026_07_19.md
)

for path in "${retired_paths[@]}"; do
  [[ ! -e "$path" ]] || {
    printf 'Retired Photo Objet collection path returned: %s\n' "$path" >&2
    exit 1
  }
done

grep -Fq 'Photo Objet automatic sales collection is permanently retired.' CLAUDE.md
grep -Fq 'Missing historical Photo collection slots are not release failures' CLAUDE.md
grep -Fq 'name: POS Release Contract' .github/workflows/pos_release_contract.yml
grep -Fq 'name: POS release contract' .github/workflows/pos_release_contract.yml
grep -Fq 'POS_REQUIRED_GITHUB_CHECK="POS release contract"' scripts/deploy_pos_production.sh

migration='supabase/migrations/20260916060000_retire_photo_objet_automatic_sales_collection.sql'
grep -Fq 'PHOTO_OBJET_AUTOMATIC_SALES_COLLECTION_RETIRED' "$migration"
grep -Fq "cron.unschedule('photo-objet-materialize-expected-slots')" "$migration"
grep -Fq 'trg_reject_photo_objet_collection_reactivation' "$migration"
grep -Fq 'REVOKE ALL ON FUNCTION' "$migration"

if rg -n \
  'photo_objet_slot_health|pull_moers_sales|Photo Objet Main Release Proof|Photo Objet Sales Contract|Photo Objet contract|photo_objet_sales_export_runs|photo_objet_expected_slots|photo_objet_monitoring_policies' \
  .github/workflows scripts/check_repo.sh scripts/deploy_pos_production.sh lib \
  docs/pos/POS_PRODUCTION_DEPLOYMENT_RUNBOOK.md; then
  printf 'Active release surfaces still reference retired Photo collection.\n' >&2
  exit 1
fi

if rg -n \
  'final Photo sales collection|sales summary has been pulled|sales pull arrived|매출 수집 시각|Lần lấy doanh số Photo Objet' \
  lib/l10n --glob '*.arb' --glob '*.dart'; then
  printf 'User-facing copy still describes Photo sales collection as active.\n' >&2
  exit 1
fi

printf 'PASS: Photo Objet automatic sales collection is permanently retired.\n'
