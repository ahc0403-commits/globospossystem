-- Production retains the current promotion/checkout wrapper; disposable SQL
-- fixtures retain the underlying atomic payment implementation. Neither changes.
BEGIN;
SET LOCAL TRANSACTION READ ONLY;
DO $preflight$
DECLARE signature text; definition text;
BEGIN
 IF to_regclass('public.direct_order_payment_receipts') IS NOT NULL
  OR to_regprocedure('public.direct_order_public_status_v5(uuid,text,uuid)') IS NOT NULL
  OR md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure)) NOT IN ('be39d85b3e5ba56462745470db5a79db','d8a48ebea4d841b76c8c340b4a5b3f92')
  OR to_regprocedure('public.direct_order_public_status_v4(uuid,text,uuid)') IS NULL
  OR to_regprocedure('public.upsert_red_invoice_intake_minimal(uuid,uuid,text,text,text,text,text,text,text,text)') IS NULL THEN
  RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_PREFLIGHT_FAILED';
 END IF;
 FOREACH signature IN ARRAY ARRAY['public.direct_order_public_submit(uuid,text,uuid,jsonb)','public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)'] LOOP
  definition:=pg_get_functiondef(signature::regprocedure);
  IF strpos(definition,'OR char_length(btrim(COALESCE(v_address->>''detail_address'', ''''))) NOT BETWEEN 1 AND 300')=0 THEN
   RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_ANCHOR_DRIFT';
  END IF;
 END LOOP;
 IF strpos(pg_get_functiondef('public.direct_order_staff_list_v3(uuid,text[],integer,text)'::regprocedure),'AND (r.created_at>=v_day_start')=0
  OR strpos(pg_get_functiondef('public.direct_order_fulfillment_context(uuid)'::regprocedure),'''paid_total'', f.final_total,')=0
  OR strpos(pg_get_functiondef('public.claim_direct_order_push_deliveries(integer)'::regprocedure),'OR r.state<>''approved''')=0
  OR strpos(pg_get_functiondef('public.direct_order_cleanup_candidates(integer)'::regprocedure),'AND request_row.pii_purged_at IS NULL')=0 THEN
  RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_ANCHOR_DRIFT';
 END IF;
END;
$preflight$;
COMMIT;
SELECT 'DIRECT_ORDER_SUPPORT_PREFLIGHT=PASS';
