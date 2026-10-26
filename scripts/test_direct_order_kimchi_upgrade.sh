#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
operating_schema="${1:?Pass a local schema-only dump of public,pos_invoice_private}"
[[ -f "$operating_schema" ]] || exit 2
fixture_name="pos-direct-kimchi-upgrade-$$"
trap 'docker rm -f "$fixture_name" >/dev/null 2>&1 || true' EXIT
docker run --detach --rm --name "$fixture_name" --env POSTGRES_PASSWORD=fixture-only public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in {1..60}; do
 if docker exec "$fixture_name" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
 sleep 1
done
run_sql() { docker exec -i --env PGPASSWORD=fixture-only "$fixture_name" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1; }
run_sql <<'SQL' >/dev/null
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON TABLES FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon,authenticated,service_role;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
SQL
run_sql < "$operating_schema" > "${TMPDIR:-/tmp}/kimchi-schema-restore-$$.log" 2>&1
run_sql < test/fixtures/store_operating_upgrade_setup.sql >/dev/null
run_sql < supabase/migrations/20261026120000_direct_order_cashier_kimchi.sql
# This has real invoice, role and stock triggers from the current production schema.
run_sql < test/sql/kimchi_consolidation_current_test.sql
