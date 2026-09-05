#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

printf 'CHECK_REPO_STEP=flutter_dependencies\n'
flutter pub get --enforce-lockfile
printf 'CHECK_REPO_STEP=static_analysis\n'
dart analyze --fatal-infos
printf 'CHECK_REPO_STEP=flutter_tests\n'
flutter test

printf 'CHECK_REPO_STEP=payroll_attendance_sql_api\n'
bash scripts/test_payroll_attendance_postgrest.sh

printf 'CHECK_REPO_STEP=financial_inputs_sql_api\n'
bash scripts/test_financial_inputs_postgrest.sh

printf 'CHECK_REPO_STEP=restaurant_report_ready_sql\n'
bash test/restaurant_sales_report_ready_sql_test.sh

printf 'CHECK_REPO_STEP=promotion_sync_sql\n'
bash scripts/test_promotion_sync_sql.sh

printf 'CHECK_REPO_STEP=measured_index_sql\n'
SCALE_INDEX_ONLY=1 bash scripts/test_scalability_isolated.sh

printf 'CHECK_REPO_STEP=direct_order_edge_contracts\n'
deno fmt --check \
  supabase/functions/direct-order-public/index.ts \
  supabase/functions/direct-order-public/index_test.ts \
  supabase/functions/direct-order-public/deno.json
deno lint \
  supabase/functions/direct-order-public/index.ts \
  supabase/functions/direct-order-public/index_test.ts
deno check --config supabase/functions/direct-order-public/deno.json \
  supabase/functions/direct-order-public/index.ts \
  supabase/functions/direct-order-public/index_test.ts
deno test --config supabase/functions/direct-order-public/deno.json \
  supabase/functions/direct-order-public/index_test.ts

printf 'CHECK_REPO_STEP=node_contracts\n'
(
  cd scripts
  PUPPETEER_SKIP_DOWNLOAD=true npm ci
  npm test
  npm audit
  npm run security-scan
)

printf 'CHECK_REPO_STEP=deploy_shell_syntax\n'
bash -n scripts/deploy_pos_production.sh
printf 'CHECK_REPO_STEP=deploy_clean_worktree_contract\n'
bash test/pos_deploy_clean_worktree_checks_test.sh
printf 'CHECK_REPO_STEP=deploy_git_history_contract\n'
bash test/pos_deploy_git_history_guard_test.sh
printf 'CHECK_REPO_STEP=production_migration_gate_contract\n'
bash test/pos_production_migration_gate_test.sh
printf 'CHECK_REPO_STEP=deploy_psql_runner_contract\n'
bash test/pos_deploy_psql_runner_test.sh
printf 'CHECK_REPO_STEP=production_sql_wrapper_contract\n'
bash test/pos_production_sql_wrapper_test.sh
printf 'CHECK_REPO_STEP=photo_expected_slot_contract\n'
bash test/photo_objet_expected_slot_ledger_test.sh
printf 'CHECK_REPO_STEP=photo_manual_import_contract\n'
bash test/photo_sales_manual_import_sql_test.sh

printf 'CHECK_REPO_STEP=restaurant_vat_integrity\n'
bash test/restaurant_vat_integrity_sql_test.sh

printf 'CHECK_REPO_STEP=flutter_web_release_build\n'
flutter build web --release
printf 'CHECK_REPO_STEP=git_whitespace_contract\n'
git diff --check
git show --check --format= HEAD
