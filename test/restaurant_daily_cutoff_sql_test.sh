#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL="$(command -v psql)"
CONTAINER="globos-restaurant-cutoff-test-$$"
HOST=127.0.0.1
TMP_DIR="$(mktemp -d)"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

docker run --detach --rm \
  --name "$CONTAINER" \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  --publish 127.0.0.1::5432 \
  postgres:15 >/dev/null
PORT="$(docker port "$CONTAINER" 5432/tcp | sed 's/.*://')"
until "$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc 'SELECT 1' \
  >/dev/null 2>&1; do
  sleep 0.2
done

run_sql() {
  "$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres \
    -X --no-psqlrc -v ON_ERROR_STOP=1 --single-transaction --file "$1"
}

query() {
  "$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres \
    -X --no-psqlrc -v ON_ERROR_STOP=1 -Atqc "$1"
}

run_sql "$ROOT_DIR/test/fixtures/restaurant_daily_cutoff_setup.sql" >/dev/null
run_sql "$ROOT_DIR/scripts/preflight_restaurant_daily_cutoff.sql" \
  | grep -q 'RESTAURANT_CUTOFF_PREFLIGHT_OK'
run_sql "$ROOT_DIR/supabase/migrations/20260716190000_restaurant_daily_cutoff.sql" \
  >/dev/null

if "$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres \
  -X --no-psqlrc -v ON_ERROR_STOP=1 \
  -v restaurant_cutoff_store_ids=81000000-0000-4000-8000-000000000002 \
  --file "$ROOT_DIR/scripts/configure_restaurant_daily_cutoff.sql" \
  >"$TMP_DIR/photo-config.log" 2>&1; then
  printf 'expected Photo activation refusal\n' >&2
  exit 1
fi
grep -q 'RESTAURANT_CUTOFF_PHOTO_STORE_FORBIDDEN' \
  "$TMP_DIR/photo-config.log"

"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres \
  -X --no-psqlrc -v ON_ERROR_STOP=1 \
  -v restaurant_cutoff_store_ids=81000000-0000-4000-8000-000000000001 \
  --file "$ROOT_DIR/scripts/configure_restaurant_daily_cutoff.sql" \
  | grep -q 'RESTAURANT_CUTOFF_CONFIGURATION_OK'
run_sql "$ROOT_DIR/scripts/verify_restaurant_daily_cutoff.sql" \
  | grep -q 'RESTAURANT_CUTOFF_VERIFY_OK'

# Trigger dependencies must remain executable under the real request role.
authenticated_phase="$(query "SET ROLE authenticated;
  SELECT public.restaurant_assert_kitchen_mutation_allowed_at(
    '81000000-0000-4000-8000-000000000001',
    '2026-07-16 21:29:59+07'
  );
  SELECT phase FROM public.restaurant_cutoff_state_at(
    '81000000-0000-4000-8000-000000000001',
    '2026-07-16 21:29:59+07'
  );")"
if [[ "$authenticated_phase" != "open" ]]; then
  printf 'authenticated cutoff helper execution failed: %s\n' \
    "$authenticated_phase" >&2
  exit 1
fi

query "DO \$test\$
DECLARE v_state record;
BEGIN
  PERFORM public.restaurant_assert_kitchen_mutation_allowed_at(
    '81000000-0000-4000-8000-000000000001',
    '2026-07-16 21:29:59+07'
  );
  BEGIN
    PERFORM public.restaurant_assert_kitchen_mutation_allowed_at(
      '81000000-0000-4000-8000-000000000001',
      '2026-07-16 21:30:00+07'
    );
    RAISE EXCEPTION 'expected kitchen boundary rejection';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> 'RESTAURANT_KITCHEN_CLOSED' THEN RAISE; END IF;
  END;

  PERFORM public.restaurant_assert_payment_allowed_at(
    '81000000-0000-4000-8000-000000000001',
    '2026-07-16 21:44:59+07'
  );
  BEGIN
    PERFORM public.restaurant_assert_payment_allowed_at(
      '81000000-0000-4000-8000-000000000001',
      '2026-07-16 21:45:00+07'
    );
    RAISE EXCEPTION 'expected sales boundary rejection';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> 'RESTAURANT_DAILY_SALES_CLOSED' THEN RAISE; END IF;
  END;

  PERFORM public.restaurant_assert_kitchen_mutation_allowed_at(
    '81000000-0000-4000-8000-000000000002',
    '2026-07-16 21:30:00+07'
  );
  PERFORM public.restaurant_assert_payment_allowed_at(
    '81000000-0000-4000-8000-000000000002',
    '2026-07-16 21:45:00+07'
  );

  SELECT * INTO STRICT v_state
  FROM public.restaurant_cutoff_state_at(
    '81000000-0000-4000-8000-000000000001',
    '2026-07-17 00:00:00+07'
  );
  IF v_state.phase <> 'open' OR v_state.business_date <> DATE '2026-07-17' THEN
    RAISE EXCEPTION 'HCM midnight state failed';
  END IF;
END
\$test\$;" >/dev/null

# Trigger coverage proves direct table/RPC writes cannot bypass the same guard.
query "SELECT count(*) FROM pg_trigger
  WHERE tgname LIKE 'trg_restaurant_cutoff_%' AND NOT tgisinternal" \
  | grep -qx 4
query "SELECT count(*) FROM pg_trigger
  WHERE tgname LIKE 'trg_restaurant_cutoff_%'
    AND pg_get_triggerdef(oid) LIKE '%BEFORE INSERT OR UPDATE%'" \
  | grep -qx 4

# Seed two clean receipts and one Photo receipt without invoking today's guard.
query "UPDATE public.restaurant_cutoff_policies SET is_enabled=false;
  INSERT INTO public.orders (id, restaurant_id, created_at) VALUES
    ('82000000-0000-4000-8000-000000000001',
     '81000000-0000-4000-8000-000000000001', '2026-07-14 19:00:00+07');
  INSERT INTO public.payments (
    id, restaurant_id, order_id, amount, created_at
  ) VALUES (
    '83000000-0000-4000-8000-000000000001',
    '81000000-0000-4000-8000-000000000001',
    '82000000-0000-4000-8000-000000000001', 100000,
    '2026-07-14 21:44:59+07'
  );
  INSERT INTO public.external_sales (
    id, restaurant_id, external_order_id, gross_amount, completed_at, created_at
  ) VALUES (
    '84000000-0000-4000-8000-000000000001',
    '81000000-0000-4000-8000-000000000001', 'delivery-clean', 50000,
    '2026-07-14 20:00:00+07', '2026-07-14 20:00:01+07'
  );
  INSERT INTO public.photo_objet_sales_raw (store_id, sold_at, amount) VALUES (
    '81000000-0000-4000-8000-000000000002',
    '2026-07-14 22:10:00+07', 75000
  );
  UPDATE public.restaurant_cutoff_policies SET is_enabled=true;" >/dev/null

query "SELECT status || '|' || receipt_count || '|' || gross_sales
  FROM public.restaurant_finalize_daily_sales_at(
    '2026-07-14', '2026-07-14 22:20:00+07'
  )" | grep -qx 'finalized|2|150000.00'
query "SELECT count(*) FROM public.v_restaurant_sales_receipts
  WHERE sale_date_hcm='2026-07-14' AND sold_at IS NOT NULL" | grep -qx 2
query "SELECT count(*) FROM public.restaurant_finalize_daily_sales_at(
    '2026-07-14', '2026-07-14 22:40:00+07'
  )" | grep -qx 1
query "SELECT count(*) FROM public.restaurant_daily_sales_finalizations
  WHERE business_date='2026-07-14'" | grep -qx 1
if query "UPDATE public.restaurant_daily_sales_finalizations
  SET status='data_integrity_failed' WHERE business_date='2026-07-14'" \
  >"$TMP_DIR/immutable.log" 2>&1; then
  printf 'expected immutable finalization failure\n' >&2
  exit 1
fi
grep -q 'RESTAURANT_FINALIZATION_IMMUTABLE' "$TMP_DIR/immutable.log"

# A legacy/integrity-incident receipt at the exact hard boundary fails closed.
query "UPDATE public.restaurant_cutoff_policies SET is_enabled=false;
  INSERT INTO public.orders (id, restaurant_id, created_at) VALUES
    ('82000000-0000-4000-8000-000000000002',
     '81000000-0000-4000-8000-000000000001', '2026-07-15 19:00:00+07');
  INSERT INTO public.payments (
    id, restaurant_id, order_id, amount, created_at
  ) VALUES (
    '83000000-0000-4000-8000-000000000002',
    '81000000-0000-4000-8000-000000000001',
    '82000000-0000-4000-8000-000000000002', 200000,
    '2026-07-15 21:45:00+07'
  );
  UPDATE public.restaurant_cutoff_policies SET is_enabled=true;" >/dev/null
query "SELECT status || '|' || post_cutoff_receipt_count || '|' ||
    (receipt_count IS NULL)::text || '|' || (gross_sales IS NULL)::text
  FROM public.restaurant_finalize_daily_sales_at(
    '2026-07-15', '2026-07-15 22:20:00+07'
  )" | grep -qx 'data_integrity_failed|1|true|true'
query "SELECT offending_stores @> '[{\"store_id\":
  \"81000000-0000-4000-8000-000000000001\",\"receipt_count\":1}]'::jsonb
  FROM public.restaurant_daily_sales_finalizations
  WHERE business_date='2026-07-15'" | grep -qx t

if query "SELECT public.restaurant_finalize_daily_sales_at(
  '2026-07-16', '2026-07-16 22:19:59+07')" \
  >"$TMP_DIR/early.log" 2>&1; then
  printf 'expected early finalization failure\n' >&2
  exit 1
fi
grep -q 'RESTAURANT_FINALIZATION_TOO_EARLY' "$TMP_DIR/early.log"

run_sql "$ROOT_DIR/scripts/rollback_restaurant_daily_cutoff.sql" \
  | grep -q 'RESTAURANT_CUTOFF_ROLLBACK_OK'
query "SELECT count(*) FROM public.restaurant_daily_sales_finalizations" \
  | grep -qx 2
query "SELECT count(*) FROM public.photo_objet_sales_raw" | grep -qx 1

# Schema replay plus explicit re-activation remains deterministic.
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres \
  -X --no-psqlrc -v ON_ERROR_STOP=1 --single-transaction \
  -v restaurant_cutoff_store_ids=81000000-0000-4000-8000-000000000001 \
  --file "$ROOT_DIR/scripts/apply_restaurant_daily_cutoff.sql" >/dev/null
run_sql "$ROOT_DIR/scripts/verify_restaurant_daily_cutoff.sql" \
  | grep -q 'RESTAURANT_CUTOFF_VERIFY_OK'

printf 'PASS: Restaurant cutoff boundaries, Photo isolation, finalization, replay, and rollback\n'
