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

# Stage 2a upgrades the line snapshot contract atomically; the old uniqueness
# guard remains until the complete choice protocol is implemented.
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < supabase/migrations/20261021170000_direct_order_line_identity.sql >/dev/null
docker exec -i --env PGPASSWORD=fixture-only "$operating_fixture" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < supabase/migrations/20261021171000_invoice_mapping_pending_marker.sql >/dev/null
run_sql < test/sql/direct_order_line_upgrade_after.sql
run_sql < test/sql/direct_order_line_identity_test.sql
run_sql < test/sql/store_operating_payment_stock_test.sql
run_sql < test/sql/store_operating_payment_concurrency_setup.sql >/dev/null
python3 scripts/tests/store_operating_payment_concurrency.py "$operating_fixture"
run_sql < test/sql/store_operating_existing_flow_test.sql
