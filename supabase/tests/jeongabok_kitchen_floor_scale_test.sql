\set ON_ERROR_STOP on
-- Isolated schema fixture only. No production data or identities are used.
BEGIN;
CREATE TEMP TABLE kds_direct_scale_results(
  active_orders integer, action text, remote_calls integer,
  elapsed_ms numeric, response_bytes integer, audit_events integer
);
DO $$
DECLARE
  scale integer; menu uuid; allocations jsonb; result jsonb; started timestamptz;
BEGIN
  FOREACH scale IN ARRAY ARRAY[10,100,500] LOOP
    INSERT INTO public.menu_items(restaurant_id,name,price)
    VALUES('273b057e-3b69-46e3-93c1-6194c2802849','Scale laboratory '||scale,10000) RETURNING id INTO menu;
    INSERT INTO public.orders(id,restaurant_id,status,created_at)
    SELECT md5('direct-scale-order:'||scale||':'||n)::uuid,
      '273b057e-3b69-46e3-93c1-6194c2802849','pending',now()+n*interval '1 millisecond'
    FROM generate_series(1,scale) n;
    INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status)
    SELECT '273b057e-3b69-46e3-93c1-6194c2802849',md5('direct-scale-order:'||scale||':'||n)::uuid,
      menu,'Scale laboratory '||scale,1,10000,'pending' FROM generate_series(1,scale) n;
    SELECT jsonb_agg(jsonb_build_object('item_id',i.id,'queue_id',i.queue_id,'source_kind','base','quantity',1))
    INTO allocations FROM public.emergency_fulfillment_items i
    JOIN public.order_items oi ON oi.id=i.order_item_id WHERE oi.menu_item_id=menu;
    ASSERT jsonb_array_length(allocations)=scale;
    PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
    started:=clock_timestamp();
    result:=public.kds_complete_kitchen_batch_v1(gen_random_uuid(),allocations);
    INSERT INTO kds_direct_scale_results VALUES(scale,'kitchen_done',1,
      extract(epoch FROM clock_timestamp()-started)*1000,octet_length(result::text),jsonb_array_length(result->'event_ids'));
    ASSERT result->>'changed_quantity'=scale::text;
    ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_tray_ready_lots WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849');
    PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000003","role":"authenticated"}',true);
    started:=clock_timestamp();
    result:=public.kds_complete_customer_delivery_batch_v1(gen_random_uuid(),allocations);
    INSERT INTO kds_direct_scale_results VALUES(scale,'floor_served',1,
      extract(epoch FROM clock_timestamp()-started)*1000,octet_length(result::text),jsonb_array_length(result->'event_ids'));
    ASSERT result->>'changed_quantity'=scale::text;
    ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_fulfillment_items i JOIN public.order_items oi ON oi.id=i.order_item_id
      WHERE oi.menu_item_id=menu AND i.floor_served_quantity<>1);
  END LOOP;
END;
$$;
TABLE kds_direct_scale_results;
ROLLBACK;
