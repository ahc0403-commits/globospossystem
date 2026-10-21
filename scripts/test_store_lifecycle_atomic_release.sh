#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
release_schema="${1:?Pass a local schema-only public,pos_invoice_private export}"
release_fixture="pos-lifecycle-atomic-$$"
release_logs="$(mktemp -d)"
cleanup() { local status=$?; if [[ "$status" != 0 ]]; then tail -20 "$release_logs"/*.log 2>/dev/null || true; fi; docker rm -f "$release_fixture" >/dev/null 2>&1 || true; rm -rf "$release_logs"; }
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
if ! run_sql < "$release_schema" > "$release_logs/restore.log" 2>&1; then tail -12 "$release_logs/restore.log"; exit 1; fi
run_sql < test/fixtures/store_operating_upgrade_setup.sql >/dev/null
run_sql < test/sql/store_operating_existing_flow_test.sql
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
run_sql < scripts/verify_store_lifecycle_release.sql
# Real stored procedures, synthetic records only, each test rolls back.
for release_test in store_operating_existing_flow_test store_operating_payment_parity_test store_workflow_bunsik_test store_workflow_direct_test sales_reporting_batches_test procurement_quality_profiles_test inventory_lots_test shared_area_receivers_test store_closure_boundaries_test store_identity_transfer_test; do
 run_sql < "test/sql/$release_test.sql"
done
printf 'STORE_LIFECYCLE_ATOMIC_REHEARSAL=PASS rollback, component history, legacy orders/payment/handoff/reporting/procurement\n'
