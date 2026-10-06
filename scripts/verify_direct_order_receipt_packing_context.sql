-- Operational probe: existing orders, actual deployed helpers, temporary tables.
-- No payment, order, snapshot, print job or customer message is persisted.
BEGIN;
DO $catalog$
BEGIN
  IF has_function_privilege('anon','public.direct_order_receipt_packing_context(uuid,uuid)','EXECUTE')
    OR NOT has_function_privilege('authenticated','public.direct_order_receipt_packing_context(uuid,uuid)','EXECUTE')
    OR has_function_privilege('authenticated','public.direct_order_enrich_digital_receipt_packing()','EXECUTE')
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.digital_receipts'::regclass
        AND tgname='zz_direct_order_enrich_digital_receipt_packing'
        AND tgfoid='public.direct_order_enrich_digital_receipt_packing()'::regprocedure
        AND tgtype=7 AND tgenabled='O')
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.print_jobs'::regclass
        AND tgname='zz_direct_order_enrich_print_fulfillment'
        AND tgfoid='public.direct_order_enrich_print_fulfillment()'::regprocedure
        AND tgtype=7 AND tgenabled='O') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PACKING_CONTRACT_VERIFICATION_FAILED';
  END IF;
END;
$catalog$;
CREATE TEMP TABLE packing_probe_jobs(order_id uuid,restaurant_id uuid,payload jsonb);
CREATE TRIGGER packing_probe BEFORE INSERT ON packing_probe_jobs FOR EACH ROW
  EXECUTE FUNCTION public.direct_order_enrich_print_fulfillment();
CREATE TEMP TABLE packing_probe_digital(order_id uuid,restaurant_id uuid,
  combined_payment_group_id uuid,snapshot jsonb);
CREATE TRIGGER packing_probe BEFORE INSERT ON packing_probe_digital FOR EACH ROW
  EXECUTE FUNCTION public.direct_order_enrich_digital_receipt_packing();
DO $operational$
DECLARE
  actor uuid; row record; context jsonb; actual jsonb;
  ordinary record; copy_type text; checked integer:=0; missing integer:=0;
BEGIN
  SELECT auth_id INTO actor FROM public.users
    WHERE role='super_admin' AND is_active AND auth_id IS NOT NULL LIMIT 1;
  IF actor IS NULL THEN RAISE EXCEPTION 'PACKING_PROBE_ACTIVE_ACTOR_REQUIRED'; END IF;
  PERFORM set_config('request.jwt.claim.sub',actor::text,true);
  FOR row IN SELECT f.order_id,f.restaurant_id,r.diner_count,r.fulfillment_method,r.reference_code
    FROM public.direct_order_financials f JOIN public.direct_order_requests r
      ON r.id=f.request_id AND r.restaurant_id=f.restaurant_id
    ORDER BY f.approved_at DESC LIMIT 20 LOOP
    context:=public.direct_order_receipt_packing_context(row.restaurant_id,row.order_id);
    IF context IS DISTINCT FROM jsonb_build_object('diner_count',row.diner_count,
      'fulfillment_method',row.fulfillment_method,'direct_order_reference',row.reference_code) THEN
      RAISE EXCEPTION 'PACKING_PROBE_NATIVE_CONTEXT_MISMATCH';
    END IF;
    FOR copy_type IN SELECT unnest(ARRAY['receipt','kitchen','floor','tray','confirmation','delivery_driver_receipt']) LOOP
      INSERT INTO packing_probe_jobs VALUES(row.order_id,row.restaurant_id,jsonb_build_object('ticket',copy_type))
        RETURNING payload INTO actual;
      IF actual->'diner_count' IS DISTINCT FROM context->'diner_count'
        OR actual->>'fulfillment_method' IS DISTINCT FROM row.fulfillment_method
        OR actual->>'direct_order_reference' IS DISTINCT FROM row.reference_code THEN
        RAISE EXCEPTION 'PACKING_PROBE_PRINT_CONTEXT_MISMATCH';
      END IF;
    END LOOP;
    INSERT INTO packing_probe_digital VALUES(row.order_id,row.restaurant_id,NULL,'{"total_amount":123,"items":[]}'::jsonb)
      RETURNING snapshot INTO actual;
    IF actual IS DISTINCT FROM context||'{"total_amount":123,"items":[]}'::jsonb THEN
      RAISE EXCEPTION 'PACKING_PROBE_DIGITAL_CONTEXT_MISMATCH';
    END IF;
    INSERT INTO packing_probe_digital VALUES(row.order_id,row.restaurant_id,gen_random_uuid(),'{"group":true}'::jsonb)
      RETURNING snapshot INTO actual;
    IF actual<>'{"group":true}'::jsonb THEN RAISE EXCEPTION 'PACKING_PROBE_COMBINED_CHANGED'; END IF;
    checked:=checked+1;
    IF row.diner_count IS NULL THEN missing:=missing+1; END IF;
  END LOOP;
  IF checked=0 THEN RAISE EXCEPTION 'PACKING_PROBE_REAL_ORDERS_REQUIRED'; END IF;
  SELECT id,restaurant_id INTO ordinary FROM public.orders o WHERE NOT EXISTS
    (SELECT 1 FROM public.direct_order_financials f WHERE f.order_id=o.id) LIMIT 1;
  IF ordinary.id IS NOT NULL THEN
    IF public.direct_order_receipt_packing_context(ordinary.restaurant_id,ordinary.id) IS NOT NULL THEN
      RAISE EXCEPTION 'PACKING_PROBE_ORDINARY_CONTEXT_CHANGED';
    END IF;
    INSERT INTO packing_probe_jobs VALUES(ordinary.id,ordinary.restaurant_id,'{}'::jsonb) RETURNING payload INTO actual;
    IF actual<>'{}'::jsonb THEN RAISE EXCEPTION 'PACKING_PROBE_ORDINARY_PRINT_CHANGED'; END IF;
    INSERT INTO packing_probe_digital VALUES(ordinary.id,ordinary.restaurant_id,NULL,'{}'::jsonb) RETURNING snapshot INTO actual;
    IF actual<>'{}'::jsonb THEN RAISE EXCEPTION 'PACKING_PROBE_ORDINARY_DIGITAL_CHANGED'; END IF;
  END IF;
  PERFORM set_config('request.jwt.claim.sub','',true);
  BEGIN
    PERFORM public.direct_order_receipt_packing_context(row.restaurant_id,row.order_id);
    RAISE EXCEPTION 'PACKING_PROBE_MISSING_ACTOR_ACCEPTED';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM<>'DIRECT_ORDER_FORBIDDEN' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PACKING_OPERATIONAL_PROBE=PASS real_orders=% forms_per_order=6 legacy_missing_count=% persisted_test_rows=0',checked,missing;
END;
$operational$;
ROLLBACK;
SELECT 'DIRECT_ORDER_PACKING_VERIFICATION=PASS';
