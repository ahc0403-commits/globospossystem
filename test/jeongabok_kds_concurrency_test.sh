#!/usr/bin/env bash
set -euo pipefail
# Explicit isolated Docker DB only; no production connection strings accepted.
: "${KDS_TEST_DATABASE:?Set KDS_TEST_DATABASE to the isolated, seeded KDS fixture database}"
KDS_TEST_CONTAINER="${KDS_TEST_CONTAINER:-supabase_db_globos_pos_system}"
[[ "$KDS_TEST_DATABASE" == jeongabok_*test* ]] || exit 2
KDS_RACE_TMP="$(mktemp -d)"
trap 'rm -rf "$KDS_RACE_TMP"' EXIT
run_sql() { docker exec -i "$KDS_TEST_CONTAINER" psql -X -U postgres -d "$KDS_TEST_DATABASE" -v ON_ERROR_STOP=1 "$@"; }
[[ "$(run_sql -Atqc "SELECT position('kds_lab_messages' in pg_get_functiondef('realtime.send(jsonb,text,text,boolean)'::regprocedure))>0")" == t ]] || exit 2
run_sql >"$KDS_RACE_TMP/seed.log" <<'SQL'
CREATE TABLE IF NOT EXISTS public.kds_direct_concurrency_lab(kitchen_request uuid,floor_request uuid,item_id uuid,queue_id uuid);
TRUNCATE public.kds_direct_concurrency_lab;
DO $$ DECLARE menu uuid; oid uuid; oi uuid; iid uuid; qid uuid;
BEGIN
 ASSERT EXISTS(SELECT 1 FROM auth.users WHERE id='92000000-0000-4000-8000-000000000001' AND email='kds-lab-1@internal.invalid');
 INSERT INTO public.menu_items(restaurant_id,name,price)
 VALUES('273b057e-3b69-46e3-93c1-6194c2802849','Concurrent laboratory',10000) RETURNING id INTO menu;
 INSERT INTO public.orders(restaurant_id,status) VALUES('273b057e-3b69-46e3-93c1-6194c2802849','pending') RETURNING id INTO oid;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status)
 VALUES('273b057e-3b69-46e3-93c1-6194c2802849',oid,menu,'Concurrent laboratory',20,10000,'pending') RETURNING id INTO oi;
 SELECT id,queue_id INTO iid,qid FROM public.emergency_fulfillment_items WHERE order_item_id=oi;
 INSERT INTO public.kds_direct_concurrency_lab VALUES(gen_random_uuid(),gen_random_uuid(),iid,qid);
END $$;
SQL
cat >"$KDS_RACE_TMP/kitchen.sql" <<'SQL'
BEGIN;
SET LOCAL request.jwt.claims='{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}';
SELECT public.kds_complete_kitchen_batch_v1(kitchen_request,jsonb_build_array(jsonb_build_object(
 'item_id',item_id,'queue_id',queue_id,'source_kind','base','quantity',20))) FROM public.kds_direct_concurrency_lab;
COMMIT;
SQL
cat >"$KDS_RACE_TMP/floor.sql" <<'SQL'
BEGIN;
SET LOCAL request.jwt.claims='{"sub":"92000000-0000-4000-8000-000000000003","role":"authenticated"}';
SELECT public.kds_complete_customer_delivery_batch_v1(floor_request,jsonb_build_array(jsonb_build_object(
 'item_id',item_id,'queue_id',queue_id,'source_kind','base','quantity',20))) FROM public.kds_direct_concurrency_lab;
COMMIT;
SQL
export KDS_TEST_CONTAINER KDS_TEST_DATABASE KDS_RACE_TMP
for KDS_RACE_KIND in kitchen floor; do
  export KDS_RACE_KIND
  seq 1 20 | xargs -P20 -n1 bash -c '
    docker exec -i "$KDS_TEST_CONTAINER" psql -X -U postgres -d "$KDS_TEST_DATABASE" -v ON_ERROR_STOP=1 \
      < "$KDS_RACE_TMP/$KDS_RACE_KIND.sql" > "$KDS_RACE_TMP/$KDS_RACE_KIND-$1.log" 2>&1
  ' _
done
python3 - "$KDS_RACE_TMP" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
for kind in ['kitchen','floor']:
    responses=[p.read_text() for p in root.glob(f'{kind}-*.log')]
    assert len(responses)==20
    assert sum('"deduplicated": false' in r for r in responses)==1, kind
    assert sum('"deduplicated": true' in r for r in responses)==19, kind
PY
run_sql <<'SQL'
DO $$ BEGIN
 ASSERT EXISTS(SELECT 1 FROM public.kds_direct_concurrency_lab l JOIN public.emergency_fulfillment_items i
   ON i.id=l.item_id WHERE i.kitchen_done_quantity=20 AND i.floor_served_quantity=20 AND i.tray_dispatched_quantity=20);
 ASSERT (SELECT count(*)=2 FROM public.emergency_fulfillment_events e JOIN public.kds_direct_concurrency_lab l
   ON e.order_item_id=(SELECT order_item_id FROM public.emergency_fulfillment_items WHERE id=l.item_id)
   WHERE e.stage IN ('kitchen_done','floor_served') AND e.delta=20);
END $$;
SQL
printf 'JEONGABOK_CONCURRENT_REPLAY=PASS clients=20 mutations_per_stage=1 duplicates_per_stage=19\n'
