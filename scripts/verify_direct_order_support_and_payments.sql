-- Production retains the current promotion/checkout wrapper; disposable SQL
-- fixtures retain the underlying atomic payment implementation. Neither changes.
-- Read existing order state only; no test orders, transfers, messages or login.
BEGIN;
SET LOCAL TRANSACTION READ ONLY;
DO $verify$
DECLARE row record; context jsonb; actor uuid; checked integer:=0;
BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure)) NOT IN ('be39d85b3e5ba56462745470db5a79db','d8a48ebea4d841b76c8c340b4a5b3f92')
  OR has_function_privilege('authenticated','public.direct_order_approve_photo_payment(uuid,uuid,numeric,uuid,uuid)','EXECUTE')
  OR has_function_privilege('anon','public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text)','EXECUTE')
  OR NOT has_function_privilege('authenticated','public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text)','EXECUTE')
  OR has_function_privilege('authenticated','public.direct_order_public_status_v5(uuid,text,uuid)','EXECUTE')
  OR NOT has_function_privilege('service_role','public.direct_order_public_status_v5(uuid,text,uuid)','EXECUTE')
  OR has_table_privilege('authenticated','public.direct_order_payment_receipts','SELECT')
  OR NOT EXISTS(SELECT 1 FROM storage.buckets WHERE id='direct-order-chat' AND NOT public AND file_size_limit=5242880)
  OR (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgenabled='O' AND tgname IN
    ('direct_order_quote_payment_notice','direct_order_charge_payment_notice','direct_order_pickup_support',
     'direct_order_dispatch_settlement','direct_order_completion_settlement','zzz_direct_order_final_receipt',
     'zzz_direct_order_final_digital_receipt','direct_order_final_receipt_completed'))<>8 THEN
  RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_RUNTIME_CONTRACT_FAILED';
 END IF;
 SELECT auth_id INTO actor FROM public.users WHERE role='super_admin' AND is_active AND auth_id IS NOT NULL LIMIT 1;
 IF actor IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_ACTIVE_ACTOR_REQUIRED'; END IF;
 PERFORM set_config('request.jwt.claim.sub',actor::text,true);
 FOR row IN SELECT r.id,r.restaurant_id,f.final_total FROM public.direct_order_requests r
  LEFT JOIN public.direct_order_financials f ON f.request_id=r.id ORDER BY r.created_at DESC LIMIT 50 LOOP
  context:=public.direct_order_staff_detail_v4(row.restaurant_id,row.id)->'support';
  IF context IS NULL OR jsonb_typeof(context->'charges')<>'array'
    OR jsonb_typeof(context->'receipts')<>'array'
    OR (row.final_total IS NOT NULL AND (context->>'food_received')::numeric<>row.final_total)
    OR public.direct_order_staff_detail_v3(row.restaurant_id,row.id) ? 'support' THEN
   RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_EXISTING_ORDER_MISMATCH';
  END IF;
  checked:=checked+1;
 END LOOP;
 IF checked=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_EXISTING_ORDERS_REQUIRED'; END IF;
 RAISE NOTICE 'DIRECT_ORDER_SUPPORT_OPERATIONAL=PASS existing_orders=% production_writes=0',checked;
END;
$verify$;
COMMIT;
SELECT 'DIRECT_ORDER_SUPPORT_VERIFICATION=PASS';
