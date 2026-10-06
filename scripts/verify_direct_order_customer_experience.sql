-- Read-only verification; does not register devices or enqueue/send notices.
DO $$
DECLARE definition text;
BEGIN
 IF to_regprocedure('public.direct_order_staff_list_v3(uuid,text[],integer,text)') IS NULL
 OR (SELECT count(*) FROM pg_trigger WHERE tgname IN
 ('direct_order_pickup_ready_notice','direct_order_pickup_conversion_notice','direct_order_driver_handoff_notice')
 AND NOT tgisinternal AND tgenabled='O')<>3
 OR has_table_privilege('anon','public.direct_order_push_devices','SELECT')
 OR has_table_privilege('authenticated','public.direct_order_push_devices','SELECT')
 OR has_function_privilege('authenticated','public.claim_direct_order_push_deliveries(integer)','EXECUTE')
 OR NOT has_function_privilege('service_role','public.claim_direct_order_push_deliveries(integer)','EXECUTE') THEN
  RAISE EXCEPTION 'CUSTOMER_EXPERIENCE_RUNTIME_CONTRACT_FAILED';
 END IF;
 definition:=pg_get_functiondef('public.sync_direct_delivery_ticket_from_kds()'::regprocedure);
 IF strpos(definition,'SET status = ''dispatched'',')>0
 OR strpos(definition,'i.ordered_quantity - i.excused_quantity')=0
 OR strpos(definition,'PERFORM 1 FROM public.direct_order_requests WHERE id=')=0
 OR strpos(definition,'PERFORM 1 FROM public.direct_order_requests WHERE id=')>
    strpos(definition,'IF public.direct_order_is_pickup_pos_order(') THEN
  RAISE EXCEPTION 'CUSTOMER_EXPERIENCE_KDS_CONTRACT_FAILED';
 END IF;
 IF current_database()<>'codex_direct_photo' THEN
 IF NOT EXISTS(
  SELECT 1 FROM cron.job WHERE jobname='direct-order-customer-push-every-minute' AND active) THEN
  RAISE EXCEPTION 'CUSTOMER_EXPERIENCE_SCHEDULER_INACTIVE';
 END IF;
 END IF;
END $$;
SELECT 'DIRECT_ORDER_CUSTOMER_EXPERIENCE_RUNTIME=PASS';
