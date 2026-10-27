#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# A local schema-only export of public,pos_invoice_private is the only input.
# Never source production configuration or connect to an existing database.
acceptance_schema="${1:?Pass a local schema-only dump of public,pos_invoice_private}"
[[ -f "$acceptance_schema" ]] || exit 2
acceptance_fixture="pos-existing-checkout-$$"
acceptance_logs="$(mktemp -d)"
cleanup() {
  docker rm -f "$acceptance_fixture" >/dev/null 2>&1 || true
  docker network rm "$acceptance_fixture" >/dev/null 2>&1 || true
  rm -rf "$acceptance_logs"
}
trap cleanup EXIT
docker network create --internal "$acceptance_fixture" >/dev/null
docker run --detach --rm --name "$acceptance_fixture" \
  --network "$acceptance_fixture" --env POSTGRES_PASSWORD=fixture-only \
  public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in {1..60}; do
  if docker exec "$acceptance_fixture" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then exit 1; fi
  sleep 1
done
run_sql() {
  docker exec -i --env PGPASSWORD=fixture-only "$acceptance_fixture" \
    psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"
}
run_sql <<'SQL' >/dev/null
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON TABLES FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon,authenticated,service_role;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
SQL
if ! run_sql < "$acceptance_schema" > "$acceptance_logs/restore.log" 2>&1; then
  tail -12 "$acceptance_logs/restore.log"
  exit 1
fi
run_sql < test/fixtures/store_operating_upgrade_setup.sql >/dev/null
run_sql <<'SQL' >/dev/null
-- The empty schema creates new draft lifecycle rows for fixture stores.
-- These two fixtures represent the already-open legacy production stores.
UPDATE public.store_lifecycle SET state='active',legacy_operational=true
WHERE restaurant_id IN('273b057e-3b69-46e3-93c1-6194c2802849','8bc9eef5-dcd5-46b1-b931-23f77132322c');
CREATE SCHEMA operating_test;
SQL
[[ "$(docker network inspect --format '{{.Internal}}' "$acceptance_fixture")" == true ]]
[[ -z "$(docker port "$acceptance_fixture")" ]]
run_sql < test/sql/store_existing_checkout_acceptance_test.sql
run_sql < test/sql/store_workflow_concurrency_setup.sql >/dev/null
python3 scripts/tests/store_workflow_concurrency.py "$acceptance_fixture"
printf 'EXISTING_STORE_CHECKOUT_ACCEPTANCE=PASS internal_network=true published_ports=0 external_workers=0 production_data=0\n'
