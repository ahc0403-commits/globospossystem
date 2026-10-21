\set ON_ERROR_STOP on
-- Isolated schema fixture only. No production data or identities are used.
BEGIN;
DO $$ BEGIN
 ASSERT current_setting('pg_stat_statements.track')='all';
 ASSERT EXISTS(SELECT 1 FROM auth.users WHERE email='kds-lab-1@internal.invalid');
END $$;
CREATE FUNCTION pg_temp.workflow_configuration_reads() RETURNS bigint LANGUAGE sql AS $count$
 SELECT coalesce(sum(calls),0)::bigint FROM pg_stat_statements
 WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database())
 AND query LIKE '%array_agg(restaurant_id)%' AND query NOT LIKE '%pg_stat_statements%' AND query NOT LIKE '%CREATE%';
$count$;
CREATE TEMP TABLE kds_direct_scale_results(
  active_orders integer, action text, remote_calls integer,
  elapsed_ms numeric, response_bytes integer, audit_events integer, configuration_reads bigint
);
DO $$
DECLARE
  scale integer; menu uuid; allocations jsonb; result jsonb; started timestamptz; configuration_before bigint; configuration_delta bigint;
BEGIN
  FOREACH scale IN ARRAY ARRAY[10,100,500] LOOP
    INSERT INTO public.menu_items(restaurant_id,name,price,portion_code,spice_level)
    VALUES('273b057e-3b69-46e3-93c1-6194c2802849','Scale laboratory '||scale,10000,'S','spicy') RETURNING id INTO menu;
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
    configuration_before:=pg_temp.workflow_configuration_reads();
    started:=clock_timestamp();
    result:=public.kds_complete_kitchen_batch_v1(gen_random_uuid(),allocations);
    configuration_delta:=pg_temp.workflow_configuration_reads()-configuration_before;
    ASSERT configuration_delta=1, 'Kitchen configuration reads grew with allocations: '||configuration_delta;
    INSERT INTO kds_direct_scale_results VALUES(scale,'kitchen_done',1,
      extract(epoch FROM clock_timestamp()-started)*1000,octet_length(result::text),jsonb_array_length(result->'event_ids'),configuration_delta);
    ASSERT result->>'changed_quantity'=scale::text;
    ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_tray_ready_lots WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849');
    PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000003","role":"authenticated"}',true);
    configuration_before:=pg_temp.workflow_configuration_reads();
    started:=clock_timestamp();
    result:=public.kds_complete_customer_delivery_batch_v1(gen_random_uuid(),allocations);
    configuration_delta:=pg_temp.workflow_configuration_reads()-configuration_before;
    ASSERT configuration_delta=1, 'Floor configuration reads grew with allocations: '||configuration_delta;
    INSERT INTO kds_direct_scale_results VALUES(scale,'floor_served',1,
      extract(epoch FROM clock_timestamp()-started)*1000,octet_length(result::text),jsonb_array_length(result->'event_ids'),configuration_delta);
    ASSERT result->>'changed_quantity'=scale::text;
    ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_fulfillment_items i JOIN public.order_items oi ON oi.id=i.order_item_id
      WHERE oi.menu_item_id=menu AND i.floor_served_quantity<>1);
  END LOOP;
END;
$$;
TABLE kds_direct_scale_results;
ROLLBACK;
