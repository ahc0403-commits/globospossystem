#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# A schema-only export supplied by the caller; this script never connects remotely.
# Export public AND pos_invoice_private so the real invoice triggers are exercised.
operating_schema="${1:?Pass a local schema-only dump of public,pos_invoice_private}"
[[ -f "$operating_schema" ]] || exit 2
operating_fixture="pos-operating-upgrade-test-$$"
operating_logs="$(mktemp -d)"
cleanup() { docker rm -f "$operating_fixture" >/dev/null 2>&1 || true; rm -rf "$operating_logs"; }
trap cleanup EXIT
docker run --detach --rm --name "$operating_fixture" --env POSTGRES_PASSWORD=fixture-only \
  public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in {1..60}; do
  if docker exec "$operating_fixture" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then exit 1; fi
  sleep 1
done
run_sql() { docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
run_sql <<'SQL' >/dev/null
-- Remove image-specific default grants before restoring the exported ACLs.
-- pg_dump assumes objects start with PostgreSQL defaults, not Supabase's
-- broad application defaults; otherwise REVOKE FROM PUBLIC leaves extra grants.
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON TABLES FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon,authenticated,service_role;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
SQL
if ! run_sql < "$operating_schema" > "$operating_logs/restore.log" 2>&1; then
  tail -12 "$operating_logs/restore.log"; exit 1
fi
run_sql < test/fixtures/store_operating_upgrade_setup.sql >/dev/null
run_sql < test/sql/store_operating_existing_flow_test.sql
run_sql < test/sql/store_operating_upgrade_before.sql >/dev/null
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < supabase/migrations/20261021163000_store_operating_profiles.sql >/dev/null
run_sql < test/sql/store_operating_upgrade_after.sql
run_sql < test/sql/store_operating_existing_flow_test.sql

run_sql < test/sql/direct_order_line_upgrade_before.sql >/dev/null
python3 - "$operating_schema" <<'PY' | run_sql >/dev/null
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
name='"public"."process_payment_without_scoped_promotions"'
start=source.index('CREATE OR REPLACE FUNCTION '+name+'(')
definition=source[start:source.index('\nALTER FUNCTION ',start)]
print(definition.replace(name,'"operating_test"."payment_before_operating"',1))
name='"public"."process_payment_before_promotion_read_split"'
start=source.index('CREATE OR REPLACE FUNCTION '+name+'(')
definition=source[start:source.index('\nALTER FUNCTION ',start)]
print(definition.replace(name,'"operating_test"."payment_wrapper_before_operating"',1)
      .replace('public.process_payment_without_scoped_promotions(', 'operating_test.payment_before_operating('))
PY

# Stage 2a upgrades the line snapshot contract atomically; the old uniqueness
# guard remains until the complete choice protocol is implemented.
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < supabase/migrations/20261021170000_direct_order_line_identity.sql >/dev/null
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < supabase/migrations/20261021171000_invoice_mapping_pending_marker.sql >/dev/null
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < supabase/migrations/20261021172000_operating_profile_purge_compat.sql >/dev/null
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < supabase/migrations/20261021173000_batch_promotion_payment_allocations.sql >/dev/null
run_sql < test/sql/store_operating_purge_contract_test.sql
run_sql < test/sql/store_operating_final_contract_test.sql
run_sql < test/sql/direct_order_line_upgrade_after.sql
run_sql < test/sql/direct_order_line_identity_test.sql
run_sql < test/sql/store_operating_payment_stock_test.sql
run_sql < test/sql/store_operating_payment_parity_test.sql
run_sql < test/sql/store_operating_payment_concurrency_setup.sql >/dev/null
python3 scripts/tests/store_operating_payment_concurrency.py "$operating_fixture"
run_sql < test/sql/store_operating_sales_contract_test.sql
run_sql < test/sql/store_operating_existing_flow_test.sql

# Stage 2b: registered choices across the real public/request/order/payment paths.
for operating_migration in \
  20261021180000_registered_menu_choices.sql \
  20261021181000_menu_choice_intake.sql \
  20261021182000_menu_choice_stock.sql; do
 docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < "supabase/migrations/$operating_migration" >/dev/null
done
run_sql < test/sql/registered_menu_choices_test.sql
run_sql < test/sql/store_operating_existing_flow_test.sql
run_sql < test/sql/direct_order_line_identity_test.sql
run_sql < test/sql/store_operating_payment_stock_test.sql
run_sql < test/sql/store_operating_payment_parity_test.sql
run_sql < test/sql/store_operating_choice_contract_test.sql

# Stages 3/4: versioned multi-kitchen preparation and guarded publication.
for operating_migration in \
  20261021190000_store_workflow_publication.sql \
  20261021191000_multi_kitchen_progress.sql \
  20261021192000_workflow_order_mutations.sql \
  20261021193000_workflow_client_scope.sql; do
 docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < "supabase/migrations/$operating_migration" >/dev/null
done
run_sql < test/sql/store_workflow_progress_test.sql
run_sql < test/sql/store_workflow_alerts_test.sql
run_sql < test/sql/store_workflow_direct_test.sql
run_sql < test/sql/store_workflow_undo_test.sql
run_sql < test/sql/store_workflow_move_fifo_test.sql
run_sql < test/sql/store_workflow_bunsik_test.sql
run_sql < test/sql/store_workflow_publication_test.sql
run_sql < test/sql/store_workflow_scale_test.sql
run_sql < test/sql/store_operating_existing_flow_test.sql
run_sql < test/sql/registered_menu_choices_test.sql
run_sql < test/sql/store_operating_payment_parity_test.sql
run_sql < test/sql/store_operating_purge_contract_test.sql
run_sql < test/sql/store_workflow_purge_test.sql
run_sql < test/sql/store_workflow_upgrade_contract_test.sql
# Store lifecycle stage 1: registration, optional physical floors, explicit areas.
for operating_migration in \
  20261021230000_owner_sales_reporting.sql \
  20261022090000_store_registration_areas.sql \
  20261022091000_service_area_kds_compat.sql; do
 docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < "supabase/migrations/$operating_migration" >/dev/null
done
run_sql < test/sql/store_registration_areas_test.sql
run_sql < test/sql/store_operating_existing_flow_test.sql
run_sql < test/sql/store_workflow_bunsik_test.sql
run_sql < test/sql/store_workflow_direct_test.sql
run_sql < test/sql/store_workflow_undo_test.sql
run_sql < test/sql/store_workflow_move_fifo_test.sql
run_sql < test/sql/store_operating_payment_parity_test.sql
run_sql < test/sql/store_operating_purge_contract_test.sql
run_sql < test/sql/store_workflow_publication_test.sql
python3 scripts/tests/store_registration_concurrency.py "$operating_fixture"

# Stage 2: explicit opening, current credentials and grandfathered legacy intake.
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
 < supabase/migrations/20261022100000_store_lifecycle_readiness.sql >/dev/null
run_sql < test/sql/store_lifecycle_readiness_test.sql
run_sql < test/sql/store_operating_existing_flow_test.sql
run_sql < test/sql/store_workflow_bunsik_test.sql
run_sql < test/sql/store_workflow_direct_test.sql
run_sql < test/sql/store_workflow_undo_test.sql
run_sql < test/sql/store_workflow_move_fifo_test.sql
run_sql < test/sql/store_operating_payment_parity_test.sql
run_sql < test/sql/store_operating_purge_contract_test.sql
run_sql < test/sql/store_workflow_publication_test.sql

# Stage 3: store identity and existing financial/receipt snapshots.
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
 < supabase/migrations/20261022110000_sales_store_identity.sql >/dev/null
run_sql < test/sql/sales_store_identity_test.sql
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
 < supabase/migrations/20261022112000_sales_reporting_batches.sql >/dev/null
run_sql < test/sql/sales_reporting_batches_test.sql
python3 scripts/tests/sales_reporting_concurrency.py "$operating_fixture"
run_sql < test/sql/store_operating_existing_flow_test.sql
run_sql < test/sql/store_operating_payment_parity_test.sql
run_sql < test/sql/store_operating_sales_contract_test.sql
run_sql < test/sql/store_operating_purge_contract_test.sql

# Stage 4: new-store procurement readiness and existing store parity.
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
 < supabase/migrations/20261022120000_procurement_readiness_profiles.sql >/dev/null
run_sql < test/sql/procurement_readiness_profiles_test.sql
run_sql < test/sql/store_operating_existing_flow_test.sql
run_sql < test/sql/store_workflow_bunsik_test.sql
run_sql < test/sql/store_workflow_direct_test.sql
run_sql < test/sql/store_operating_payment_parity_test.sql
run_sql < test/sql/store_operating_purge_contract_test.sql
run_sql < test/sql/store_workflow_publication_test.sql

# Stage 5: approved quality criteria and frozen receipt evidence.
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
 < supabase/migrations/20261022130000_procurement_quality_profiles.sql >/dev/null
run_sql < test/sql/procurement_quality_profiles_test.sql
run_sql < test/sql/store_operating_existing_flow_test.sql
run_sql < test/sql/store_workflow_bunsik_test.sql
run_sql < test/sql/store_workflow_direct_test.sql
run_sql < test/sql/store_operating_payment_parity_test.sql
run_sql < test/sql/store_operating_purge_contract_test.sql
run_sql < test/sql/store_workflow_publication_test.sql

# Stage 6: opt-in lots, opening counts, quarantine and receipt lineage.
for operating_migration in \
  20261022140000_inventory_lot_foundation.sql \
  20261022141000_inventory_lot_counts.sql \
  20261022142000_inventory_receipt_lots.sql \
  20261022143000_inventory_lot_dispositions.sql \
  20261022144000_inventory_lot_workspace.sql \
  20261022145000_inventory_lot_boundaries.sql; do
 docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < "supabase/migrations/$operating_migration" >/dev/null
done
run_sql < test/sql/inventory_lots_test.sql
python3 scripts/tests/inventory_lot_concurrency.py "$operating_fixture"
run_sql < test/sql/procurement_quality_profiles_test.sql
run_sql < test/sql/store_operating_existing_flow_test.sql
run_sql < test/sql/store_workflow_bunsik_test.sql
run_sql < test/sql/store_workflow_direct_test.sql
run_sql < test/sql/store_operating_payment_parity_test.sql
run_sql < test/sql/store_operating_purge_contract_test.sql
run_sql < test/sql/store_workflow_publication_test.sql

# Shared receiver keeps the two stores' legacy area scopes unchanged.
run_sql -Atc "SELECT store_workflow_source('273b057e-3b69-46e3-93c1-6194c2802849'),store_workflow_source('8bc9eef5-dcd5-46b1-b931-23f77132322c');" > "$operating_logs/area-before"
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
 < supabase/migrations/20261022150000_shared_service_area_receivers.sql >/dev/null
run_sql -Atc "SELECT store_workflow_source('273b057e-3b69-46e3-93c1-6194c2802849'),store_workflow_source('8bc9eef5-dcd5-46b1-b931-23f77132322c');" > "$operating_logs/area-after"
cmp "$operating_logs/area-before" "$operating_logs/area-after"
run_sql < test/sql/shared_area_receivers_test.sql
run_sql < test/sql/store_workflow_bunsik_test.sql
run_sql < test/sql/store_workflow_direct_test.sql
run_sql < test/sql/store_workflow_undo_test.sql
run_sql < test/sql/store_workflow_move_fifo_test.sql
run_sql < test/sql/store_operating_existing_flow_test.sql
run_sql < test/sql/store_operating_payment_parity_test.sql
run_sql < test/sql/store_workflow_publication_test.sql
# Stage 7: operating acceptance, external reconciliation evidence and closure/reopening.
for operating_migration in \
  20261022160000_store_closure_boundaries.sql \
  20261022170000_store_operational_acceptance.sql \
  20261022180000_procurement_reconciliation_evidence.sql \
  20261022181000_store_reopening_preparation.sql \
  20261022182000_procurement_quality_review.sql \
  20261022190000_procurement_demand_initial_plans.sql \
  20261022191000_store_identity_transfers.sql \
  20261022192000_lifecycle_read_boundaries.sql \
  20261022193000_lifecycle_financial_boundaries.sql; do
 docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < "supabase/migrations/$operating_migration" >/dev/null
done
run_sql < test/sql/store_operational_acceptance_test.sql
run_sql < test/sql/procurement_reconciliation_evidence_test.sql
run_sql < test/sql/store_closure_boundaries_test.sql
run_sql < test/sql/store_identity_transfer_test.sql
run_sql < test/sql/procurement_demand_initial_test.sql
run_sql < test/sql/procurement_demand_client_compat_test.sql
run_sql -c "SET test.held_price=130" -f - < test/sql/inventory_lots_test.sql
run_sql < test/sql/store_operating_purge_contract_test.sql
run_sql < test/sql/store_workflow_bunsik_test.sql
run_sql < test/sql/store_workflow_direct_test.sql
run_sql < test/sql/store_workflow_undo_test.sql
run_sql < test/sql/store_workflow_move_fifo_test.sql
run_sql < test/sql/store_operating_existing_flow_test.sql
run_sql < test/sql/store_operating_payment_parity_test.sql
run_sql < test/sql/store_workflow_publication_test.sql
run_sql < test/sql/store_workflow_concurrency_setup.sql >/dev/null
python3 scripts/tests/store_workflow_concurrency.py "$operating_fixture"
