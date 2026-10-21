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
run_sql() { docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1; }
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
run_sql < test/sql/store_workflow_concurrency_setup.sql >/dev/null
python3 scripts/tests/store_workflow_concurrency.py "$operating_fixture"
