#!/usr/bin/env bash
set -euo pipefail
PHOTO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHOTO_TMP="$(mktemp -d)"
PHOTO_CONTAINER="globos-direct-photo-test-$$"
cleanup() { docker rm -f "$PHOTO_CONTAINER" >/dev/null 2>&1 || true; rm -rf "$PHOTO_TMP"; }
trap cleanup EXIT
python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PY'
from pathlib import Path
import re,sys
root,tmp=map(Path,sys.argv[1:])
mdir=root/'supabase/migrations'
def source(file): return (mdir/file).read_text()
def function(file,name):
 s=source(file);m=re.search(r'CREATE (?:OR REPLACE )?FUNCTION public\.'+name+r'\(',s)
 if not m: raise RuntimeError(name)
 return s[m.start():s.index('$$;',m.start())+3]+'\n'
def block(file,label):
 s=source(file);start=s.index('DO $'+label+'$')
 return s[start:s.index('$'+label+'$;',start)+len(label)+3]+'\n'
base='20260821130000_direct_delivery_ordering.sql'
out=''
for file in ['20260805120000_sepay_bank_transfer_alerts.sql',base]:
 for m in re.finditer(r'CREATE TABLE (?:IF NOT EXISTS )?public\.\w+ \(',source(file)):
  s=source(file);out+=s[m.start():s.index('\n);',m.start())+4]+'\n'
s=source('20260910130000_direct_order_customer_payment_and_status.sql')
a=s.index('CREATE TABLE public.direct_order_proof_review_requests (')
out+=s[a:s.index('\n);',a)+4]+'\n'
out+=function('20260707010000_service_item_exclusion_v1.sql','process_payment')
out+=function(base,'direct_order_require_actor')
out+=function(base,'direct_order_public_submit')
out+=function(base,'direct_order_staff_quote')
out+=function(base,'direct_order_approve_payment')
out+='REVOKE ALL ON FUNCTION public.direct_order_approve_payment(uuid,uuid,numeric,text) FROM PUBLIC,anon;\n'
out+='GRANT EXECUTE ON FUNCTION public.direct_order_approve_payment(uuid,uuid,numeric,text) TO authenticated;\n'
pilot=source('20260908120000_direct_order_pilot_safety.sql')
out+=pilot[pilot.index('ALTER TABLE public.direct_order_quotes'):pilot.index('COMMENT ON COLUMN')]
out+=block('20260907150000_cashier_direct_delivery_availability.sql','patch_existing_requests')
out+=block('20260908120000_direct_order_pilot_safety.sql','proof_or_verified_payment')
out+=block('20260910130000_direct_order_customer_payment_and_status.sql','block_approval_during_review')
out+=function('20260908120000_direct_order_pilot_safety.sql','enqueue_direct_order_customer_receipt_after_payment')
out+='CREATE TRIGGER direct_order_customer_receipt_after_payment AFTER INSERT ON public.direct_order_financials FOR EACH ROW EXECUTE FUNCTION public.enqueue_direct_order_customer_receipt_after_payment();\n'
(tmp/'predecessor.sql').write_text(out)
PY
docker run --detach --rm --name "$PHOTO_CONTAINER" \
 --env POSTGRES_HOST_AUTH_METHOD=trust --env POSTGRES_DB=codex_direct_photo postgres:15 >/dev/null
for ((attempt=0;attempt<60;attempt++)); do
 if docker exec "$PHOTO_CONTAINER" pg_isready -h 127.0.0.1 -U postgres -d codex_direct_photo >/dev/null 2>&1; then break; fi
 sleep 1
done
run_sql() { docker exec -i "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 < "$1"; }
run_sql "$PHOTO_ROOT/test/fixtures/restaurant_vat_integrity_setup.sql" > "$PHOTO_TMP/setup.log" 2>&1 || { cat "$PHOTO_TMP/setup.log"; exit 1; }
run_sql "$PHOTO_ROOT/test/fixtures/direct_order_photo_approval_setup.sql" >> "$PHOTO_TMP/setup.log" 2>&1 || { cat "$PHOTO_TMP/setup.log"; exit 1; }
# Keep diagnostics visible on failure without exposing any production data.
run_sql "$PHOTO_TMP/predecessor.sql" > "$PHOTO_TMP/predecessor.log" 2>&1 || { cat "$PHOTO_TMP/predecessor.log"; exit 1; }
run_sql "$PHOTO_ROOT/supabase/migrations/20260824040000_direct_order_pilot_actions_and_progress.sql" >/dev/null
run_sql "$PHOTO_ROOT/supabase/tests/fixtures/direct_delivery_test_clock.sql" >/dev/null
run_sql "$PHOTO_ROOT/test/fixtures/direct_order_photo_approval_requests.sql" >/dev/null
# The original failure is reproduced before applying the fix.
run_sql "$PHOTO_ROOT/test/sql/direct_order_photo_approval_before.sql"
PHOTO_PAYMENT_HASH="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
 "select md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))")"
run_sql "$PHOTO_ROOT/supabase/migrations/20261003060838_direct_order_customer_photo_approval.sql" >/dev/null
PHOTO_PAYMENT_HASH_AFTER="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
 "select md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))")"
[[ "$PHOTO_PAYMENT_HASH" == "$PHOTO_PAYMENT_HASH_AFTER" ]] || { printf 'PAYMENT_ANCHOR_CHANGED\n'; exit 1; }
run_sql "$PHOTO_ROOT/supabase/tests/direct_order_photo_approval_contract_test.sql"
# Two independent database sessions approve the same reviewed photo.
PHOTO_ARGS="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
 "select concat_ws(',',f->>'store_id',f->>'request_id',f->>'quote_id',f->>'proof_id') from (select photo_test.create_request() f) x")"
IFS=',' read -r PHOTO_STORE PHOTO_REQUEST PHOTO_QUOTE PHOTO_PROOF <<< "$PHOTO_ARGS"
PHOTO_CALL="select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',false); select public.direct_order_approve_photo_payment('$PHOTO_STORE','$PHOTO_REQUEST',108000,'$PHOTO_QUOTE','$PHOTO_PROOF');"
docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "$PHOTO_CALL" > "$PHOTO_TMP/a.log" 2>&1 &
PHOTO_PID_A=$!
docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "$PHOTO_CALL" > "$PHOTO_TMP/b.log" 2>&1 &
PHOTO_PID_B=$!
wait "$PHOTO_PID_A" || { cat "$PHOTO_TMP/a.log"; exit 1; }
wait "$PHOTO_PID_B" || { cat "$PHOTO_TMP/b.log"; exit 1; }
docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c \
 "select photo_test.assert_single_graph('$PHOTO_REQUEST'); DO \$\$ BEGIN IF (SELECT current_stock FROM public.inventory_items LIMIT 1)<>9990 THEN RAISE EXCEPTION 'CONCURRENT_APPROVAL_DUPLICATED_STOCK_DEDUCTION'; END IF; END \$\$;" >/dev/null
printf 'DIRECT_ORDER_PHOTO_APPROVAL_SQL_TEST=PASS\n'
printf 'DIRECT_ORDER_PHOTO_APPROVAL_CONCURRENCY=PASS\n'
