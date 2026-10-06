#!/usr/bin/env bash
set -euo pipefail
# Debian/Ubuntu keep server binaries outside PATH; Homebrew puts them on PATH.
if ! command -v initdb >/dev/null 2>&1 && command -v pg_config >/dev/null 2>&1; then
  export PATH="$(pg_config --bindir):$PATH"
fi
for inventory_tool in initdb pg_ctl psql python3; do
  command -v "$inventory_tool" >/dev/null || { echo "Required test tool missing: $inventory_tool" >&2; exit 1; }
done
INVENTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/inventory-workflow.XXXXXX")"
INVENTORY_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1', 0))
    print(s.getsockname()[1])
PY
)"
cleanup() {
  pg_ctl -D "$INVENTORY_TMP/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$INVENTORY_TMP"
}
trap cleanup EXIT
initdb -D "$INVENTORY_TMP/data" --auth=trust --encoding=UTF8 --locale=C >/dev/null
pg_ctl -D "$INVENTORY_TMP/data" -l "$INVENTORY_TMP/server.log" -o "-h 127.0.0.1 -p $INVENTORY_PORT -k $INVENTORY_TMP" -w start >/dev/null
python3 "$INVENTORY_ROOT/scripts/tests/inventory_workflow_fixture.py" "$INVENTORY_ROOT" "$INVENTORY_TMP/base.sql"
run_sql() { psql -X -h 127.0.0.1 -p "$INVENTORY_PORT" -d postgres -v ON_ERROR_STOP=1 -f "$1"; }
run_sql "$INVENTORY_ROOT/test/fixtures/inventory_workflow_setup.sql" >/dev/null
run_sql "$INVENTORY_TMP/base.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260911100000_inventory_workflow_all_stores.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260911150000_inventory_order_quantity_image_warning.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260913140000_procurement_receiving_integrity.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_receiving_integrity.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260913150000_procurement_v2_requests_orders.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260913151000_procurement_v2_read_and_legacy_guards.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260913160000_procurement_receiving_inspection.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_receiving_inspection.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260913161000_procurement_followup_commands.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_followup_commands.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260913162000_procurement_accounting_snapshot.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_accounting_snapshot.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260913180000_procurement_demand_evidence.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_demand_evidence.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260913201000_procurement_supplier_evidence.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_supplier_evidence.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260913202000_procurement_legacy_terms_review.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_legacy_terms_review.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/tests/inventory_workflow_all_stores_test.sql"
python3 "$INVENTORY_ROOT/scripts/tests/inventory_workflow_concurrency.py" "$INVENTORY_PORT"
run_sql "$INVENTORY_ROOT/scripts/verify_inventory_workflow_all_stores.sql"

run_sql "$INVENTORY_ROOT/supabase/tests/procurement_receiving_integrity.test.sql"
run_sql "$INVENTORY_ROOT/supabase/tests/procurement_v2_workflow.test.sql"
run_sql "$INVENTORY_ROOT/scripts/preflight_inventory_receipt_submission_lock_audit.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260927010000_inventory_receipt_submission_lock_audit.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_inventory_receipt_submission_lock_audit.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/tests/inventory_receipt_submission_lock_audit.test.sql"
run_sql "$INVENTORY_ROOT/scripts/preflight_inventory_workflow_order_search.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20260927011000_inventory_workflow_order_search.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_inventory_workflow_order_search.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/tests/inventory_workflow_order_search.test.sql"

run_sql "$INVENTORY_ROOT/supabase/tests/procurement_upgrade_fixture.sql"
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005030000_procurement_process_contract.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_process_contract.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005031000_procurement_documents_and_channel.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_documents_and_channel.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005032000_procurement_paged_reads.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_paged_reads.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005033000_procurement_set_based_evidence.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_set_based_evidence.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005034000_procurement_nonstock_returns.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_nonstock_returns.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005035000_procurement_document_storage_scope.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_document_storage_scope.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005036000_procurement_legacy_entry_and_evidence.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_legacy_entry_and_evidence.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005037000_procurement_accounting_status.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_accounting_status.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005039000_procurement_role_roster_and_metrics.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_role_roster_and_metrics.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005040000_procurement_read_indexes.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_read_indexes.sql" >/dev/null
python3 "$INVENTORY_ROOT/scripts/tests/procurement_fixed_account_fixture.py" "$INVENTORY_ROOT" "$INVENTORY_TMP/fixed-accounts.sql"
run_sql "$INVENTORY_TMP/fixed-accounts.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005041000_procurement_store_verifier_accounts.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005042000_procurement_shared_role_roster.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/migrations/20261005043000_procurement_employee_payment_owners.sql" >/dev/null
run_sql "$INVENTORY_ROOT/scripts/verify_procurement_employee_payment_owners.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/tests/procurement_upgrade_compatibility.test.sql"
run_sql "$INVENTORY_ROOT/supabase/tests/procurement_process_contract.test.sql"

run_sql "$INVENTORY_ROOT/supabase/tests/procurement_paged_reads.test.sql"
run_sql "$INVENTORY_ROOT/supabase/tests/procurement_shared_roles.test.sql"

run_sql "$INVENTORY_ROOT/supabase/migrations/20261006010000_procurement_combined_receiving.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/tests/procurement_combined_receiving.test.sql"
# Preserve independent confirmation and stock invariants after the new mode.
run_sql "$INVENTORY_ROOT/supabase/tests/procurement_receiving_integrity.test.sql"

run_sql "$INVENTORY_ROOT/supabase/migrations/20261006011000_procurement_account_audit_auth_actor.sql" >/dev/null
run_sql "$INVENTORY_ROOT/supabase/tests/procurement_account_audit_auth_actor.test.sql"

python3 "$INVENTORY_ROOT/scripts/tests/procurement_query_performance.py" "$INVENTORY_PORT" "$INVENTORY_ROOT"
