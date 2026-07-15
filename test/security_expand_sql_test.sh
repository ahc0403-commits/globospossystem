#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PGHOST_VALUE="${LOCAL_PGHOST:-127.0.0.1}"
PGPORT_VALUE="${LOCAL_PGPORT:-54322}"
PGUSER_VALUE="${LOCAL_PGUSER:-postgres}"
PGPASSWORD_VALUE="${LOCAL_PGPASSWORD:-postgres}"
DB_NAME="globos_security_expand_test_$$"

[[ "$PGHOST_VALUE" == "127.0.0.1" || "$PGHOST_VALUE" == "localhost" ]] || {
  printf 'ERROR: security SQL test refuses non-local PostgreSQL hosts.\n' >&2
  exit 1
}

cleanup() {
  PGPASSWORD="$PGPASSWORD_VALUE" dropdb \
    --if-exists \
    --host "$PGHOST_VALUE" \
    --port "$PGPORT_VALUE" \
    --username "$PGUSER_VALUE" \
    "$DB_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

PGPASSWORD="$PGPASSWORD_VALUE" createdb \
  --host "$PGHOST_VALUE" \
  --port "$PGPORT_VALUE" \
  --username "$PGUSER_VALUE" \
  --template template0 \
  "$DB_NAME"

psql_local() {
  PGPASSWORD="$PGPASSWORD_VALUE" psql \
    -X --no-psqlrc -v ON_ERROR_STOP=1 \
    --host "$PGHOST_VALUE" \
    --port "$PGPORT_VALUE" \
    --username "$PGUSER_VALUE" \
    --dbname "$DB_NAME" \
    "$@"
}

psql_local --file "$ROOT_DIR/test/fixtures/security_expand_local_setup.sql" >/dev/null
psql_local --file "$ROOT_DIR/scripts/preflight_security_audit_hardening.sql" >/dev/null
psql_local --file "$ROOT_DIR/supabase/migrations/20260715000000_security_audit_hardening.sql" >/dev/null
psql_local --file "$ROOT_DIR/scripts/verify_security_audit_hardening.sql" >/dev/null
psql_local --file "$ROOT_DIR/scripts/preflight_security_expand_compat.sql" >/dev/null
psql_local --file "$ROOT_DIR/supabase/migrations/20260715020000_security_expand_compat.sql" >/dev/null
psql_local --file "$ROOT_DIR/scripts/verify_security_expand_compat.sql" >/dev/null
psql_local --file "$ROOT_DIR/test/fixtures/security_expand_assert.sql" >/dev/null
psql_local --file "$ROOT_DIR/supabase/migrations/20260715020000_security_expand_compat.sql" >/dev/null
psql_local --file "$ROOT_DIR/scripts/verify_security_expand_compat.sql" >/dev/null

concurrent_call() {
  psql_local --command "
    SELECT set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', false);
    SELECT id FROM public.process_payment(
      '30000000-0000-0000-0000-000000000003',
      '11111111-1111-1111-1111-111111111111',
      300.00,
      'CASH',
      '40000000-0000-0000-0000-000000000003'
    );
  " >/dev/null
}

concurrent_call &
first_pid=$!
concurrent_call &
second_pid=$!
wait "$first_pid"
wait "$second_pid"

psql_local --command "
  DO \$assert\$
  BEGIN
    IF (SELECT count(*) FROM public.payments
        WHERE order_id = '30000000-0000-0000-0000-000000000003') <> 1
       OR (SELECT count(*) FROM public.einvoice_jobs j
           JOIN public.payments p ON p.id = j.payment_id
           WHERE p.order_id = '30000000-0000-0000-0000-000000000003') <> 1 THEN
      RAISE EXCEPTION 'CONCURRENT_PAYMENT_NOT_IDEMPOTENT';
    END IF;
  END;
  \$assert\$;
" >/dev/null

set +e
guard_output="$(psql_local \
  --file "$ROOT_DIR/docs/security_rollout/sql/security_contract_draft.sql" 2>&1)"
guard_status=$?
set -e
[[ "$guard_status" -ne 0 ]]
[[ "$guard_output" == *'SECURITY_CONTRACT_APPROVAL_REQUIRED'* ]]

psql_local \
  --command "SELECT set_config('app.security_contract_approved', 'GLOBOS_SECURITY_CONTRACT_APPROVED', false);" \
  --file "$ROOT_DIR/docs/security_rollout/sql/security_contract_draft.sql" >/dev/null
psql_local --file "$ROOT_DIR/test/fixtures/security_contract_assert.sql" >/dev/null

psql_local \
  --command "SELECT set_config('app.security_contract_emergency_regrant', 'GLOBOS_SECURITY_COMPATIBILITY_REGRANT', false);" \
  --file "$ROOT_DIR/docs/security_rollout/sql/security_contract_emergency_regrant.sql" >/dev/null
psql_local --command "
  DO \$assert\$
  BEGIN
    IF NOT has_function_privilege(
      'authenticated', 'public.process_payment(uuid,uuid,numeric,text)', 'EXECUTE'
    ) OR NOT has_function_privilege(
      'authenticated', 'public.attach_payment_proof(uuid,uuid,text,timestamp with time zone)', 'EXECUTE'
    ) OR NOT has_function_privilege(
      'authenticated', 'public.set_payroll_pin(uuid,text)', 'EXECUTE'
    ) THEN
      RAISE EXCEPTION 'EMERGENCY_REGRANT_FAILED';
    END IF;
  END;
  \$assert\$;
" >/dev/null

printf 'PASS: isolated Security Audit, Expand, concurrency, PIN, proof, Contract, and regrant SQL\n'
