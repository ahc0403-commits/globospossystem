#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
release_schema="${1:?Pass a local schema-only public,pos_invoice_private export}"
release_deployed="${2:-}"
[[ -z "$release_deployed" || "$release_deployed" == "--deployed-schema" ]] || exit 2
release_fixture="pos-lifecycle-atomic-$$"
release_logs="$(mktemp -d)"
cleanup() { local status=$?; if [[ "$status" != 0 ]]; then tail -20 "$release_logs/restore.log" "$release_logs/rollback.log" "$release_logs/apply.log" 2>/dev/null || true; fi; docker rm -f "$release_fixture" >/dev/null 2>&1 || true; rm -rf "$release_logs"; }
trap cleanup EXIT
python3 scripts/build_store_lifecycle_release.py --check
docker run --detach --rm --name "$release_fixture" --env POSTGRES_PASSWORD=fixture-only public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in {1..60}; do
 if docker exec "$release_fixture" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i --env PGPASSWORD=fixture-only "$release_fixture" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
run_sql <<'SQL' >/dev/null
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON TABLES FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon,authenticated,service_role;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations(version text PRIMARY KEY,name text,statements text[]);
GRANT USAGE ON SCHEMA supabase_migrations TO postgres;
GRANT SELECT,INSERT ON supabase_migrations.schema_migrations TO postgres;
INSERT INTO supabase_migrations.schema_migrations(version,name) VALUES('20261021230000','owner_sales_reporting') ON CONFLICT DO NOTHING;
SQL
python3 - "$release_schema" > "$release_logs/restore.sql" <<'PYRESTORE'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
s=re.sub(r'(?m)^CREATE SCHEMA (public|"public");$',r'CREATE SCHEMA IF NOT EXISTS \1;',s)
print(s)
PYRESTORE
if ! run_sql < "$release_logs/restore.sql" > "$release_logs/restore.log" 2>&1; then tail -12 "$release_logs/restore.log"; exit 1; fi
run_sql < test/fixtures/store_operating_upgrade_setup.sql >/dev/null
if [[ "$release_deployed" == "--deployed-schema" ]]; then
 run_sql -c "UPDATE public.store_lifecycle SET state='active',legacy_operational=true; ALTER TABLE public.orders DISABLE TRIGGER store_capture_sale_identity;" >/dev/null
fi
run_sql < test/sql/store_operating_existing_flow_test.sql
if [[ -z "$release_deployed" ]]; then
run_sql -c 'CREATE SCHEMA operating_test;' >/dev/null
python3 - "$release_schema" <<'PYPAYMENT' | run_sql >/dev/null
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
print(definition.replace(name,'"operating_test"."payment_wrapper_before_operating"',1).replace('public.process_payment_without_scoped_promotions(', 'operating_test.payment_before_operating('))
PYPAYMENT
fi
# A real pre-upgrade paid receipt proves the historical-name fallback and the
# immutable-receipt anchor; these records exist only in this disposable DB.
run_sql <<'SQLLEGACY' >/dev/null
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
DO $$ DECLARE shop uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c'; menu uuid; ord uuid; BEGIN
 UPDATE brands SET service_charge_enabled=false WHERE id='91000000-0000-4000-8000-000000000003';
 UPDATE restaurants SET vat_pricing_mode='exclusive' WHERE id=shop;
 PERFORM approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004','legacy-receipt-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','Isolated pre-upgrade receipt');
 INSERT INTO menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price) VALUES(shop,'Legacy receipt meal','Món thử trước cập nhật','Phần',10000) RETURNING id INTO menu;
 INSERT INTO orders(restaurant_id,status) VALUES(shop,'serving') RETURNING id INTO ord;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status) VALUES(shop,ord,menu,'Legacy receipt meal',1,10000,'served');
 PERFORM process_payment(ord,shop,10800,'CASH');
END $$;
COMMIT;
SQLLEGACY
if [[ "$release_deployed" == "--deployed-schema" ]]; then
 run_sql -c 'ALTER TABLE public.orders ENABLE TRIGGER store_capture_sale_identity;' >/dev/null
 python3 - <<'PYHISTORY' | run_sql >/dev/null
from scripts.build_store_lifecycle_release import COMPONENTS
for name in COMPONENTS:
 version,slug=name[:-4].split('_',1)
 print("INSERT INTO supabase_migrations.schema_migrations(version,name) VALUES ('%s','%s') ON CONFLICT DO NOTHING;" % (version,slug))
PYHISTORY
else
run_sql < scripts/preflight_store_lifecycle_release.sql
# Prove that a transaction-wide rollback leaves neither schema nor component history.
python3 - <<'PY' | docker exec -i --env PGPASSWORD=fixture-only "$release_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 > "$release_logs/rollback.log" 2>&1
from pathlib import Path
s=Path('scripts/releases/20261022200000_store_lifecycle_release.sql').read_text()
assert s.endswith('COMMIT;\n')
print(s[:-len('COMMIT;\n')]+'ROLLBACK;')
PY
run_sql <<'SQL'
DO $$ BEGIN
 ASSERT to_regclass('public.store_lifecycle') IS NULL;
 ASSERT NOT EXISTS(SELECT 1 FROM supabase_migrations.schema_migrations WHERE version BETWEEN '20261021163000' AND '20261022193000' AND version<>'20261021230000');
END $$;
SQL
if ! docker exec -i --env PGPASSWORD=fixture-only "$release_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 < scripts/releases/20261022200000_store_lifecycle_release.sql > "$release_logs/apply.log" 2>&1; then tail -20 "$release_logs/apply.log"; exit 1; fi
fi
run_sql < scripts/verify_store_lifecycle_release.sql
if [[ -n "${STORE_LIFECYCLE_REHEARSED_SCHEMA_OUT:-}" ]]; then
 docker exec --env PGPASSWORD=fixture-only "$release_fixture" pg_dump -U supabase_admin -d postgres --schema-only --schema public --schema pos_invoice_private > "$STORE_LIFECYCLE_REHEARSED_SCHEMA_OUT"
fi
if [[ -z "$release_deployed" ]]; then run_sql < test/sql/store_operating_payment_parity_test.sql; fi
# Real stored procedures, synthetic records only, each test rolls back.
for release_test in store_operating_existing_flow_test store_operating_payment_stock_test store_workflow_bunsik_test store_workflow_direct_test sales_reporting_batches_test procurement_demand_client_compat_test procurement_quality_profiles_test inventory_lots_test shared_area_receivers_test store_closure_boundaries_test store_identity_transfer_test; do
 run_sql < "test/sql/$release_test.sql"
done
if [[ -n "$release_deployed" ]]; then
 printf 'STORE_LIFECYCLE_DEPLOYED_SCHEMA=PASS current functions, orders/payment/handoff/reporting/procurement\n'
else
 printf 'STORE_LIFECYCLE_ATOMIC_REHEARSAL=PASS rollback, component history, legacy orders/payment/handoff/reporting/procurement\n'
fi
