-- Run only after a no-duplicate-preparation confirmation and the gated migration.
-- psql -v pickup_store_id=<uuid> -v pickup_request_id=<uuid> -f this_file
\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('app.pickup_recovery_store', :'pickup_store_id', true),
       set_config('app.pickup_recovery_request', :'pickup_request_id', true);
CREATE FUNCTION pg_temp.pickup_financial_hash(p_order_id uuid) RETURNS text LANGUAGE sql AS $$
 SELECT md5(jsonb_build_object(
  'order',(SELECT to_jsonb(o) FROM public.orders o WHERE o.id=p_order_id),
  'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM public.order_items i WHERE i.order_id=p_order_id),
  'payments',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM public.payments p WHERE p.order_id=p_order_id),
  'financial',(SELECT to_jsonb(f) FROM public.direct_order_financials f WHERE f.order_id=p_order_id),
  'stock_transactions',(SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text) FROM public.inventory_transactions t
    JOIN public.order_items i ON i.id=t.reference_id WHERE i.order_id=p_order_id)
 )::text)
$$;
DO $$ DECLARE store_id uuid:=current_setting('app.pickup_recovery_store')::uuid;
 request_uuid uuid:=current_setting('app.pickup_recovery_request')::uuid;
 order_uuid uuid; before_hash text; result jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('direct-order-approval:'||request_uuid::text,0));
 SELECT f.order_id INTO STRICT order_uuid FROM public.direct_order_financials f
 WHERE f.request_id=request_uuid AND f.restaurant_id=store_id;
 IF NOT EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets t
  WHERE t.request_id=request_uuid AND t.restaurant_id=store_id AND t.status='pending') THEN
  RAISE EXCEPTION 'PICKUP_RECOVERY_REQUIRES_UNSTARTED_TICKET'; END IF;
 before_hash:=pg_temp.pickup_financial_hash(order_uuid);
 result:=public.enqueue_direct_pickup_kds(store_id,request_uuid);
 IF result->>'status'<>'queued' OR before_hash IS DISTINCT FROM pg_temp.pickup_financial_hash(order_uuid) THEN
  RAISE EXCEPTION 'PICKUP_RECOVERY_RECONCILIATION_FAILED'; END IF;
 IF EXISTS(SELECT 1 FROM public.emergency_fulfillment_items i WHERE i.order_id=order_uuid
  AND (i.kitchen_done_quantity<>0 OR i.tray_received_quantity<>0 OR i.tray_dispatched_quantity<>0)) THEN
  RAISE EXCEPTION 'PICKUP_RECOVERY_ALREADY_STARTED'; END IF;
 RAISE NOTICE 'PICKUP_RECOVERY_VERIFIED: %',result;
END $$;
COMMIT;
