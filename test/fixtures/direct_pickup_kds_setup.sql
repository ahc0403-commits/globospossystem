DO $$ BEGIN
 IF current_database() <> 'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
END $$;
CREATE SCHEMA pickup_kds_test;
ALTER TABLE public.order_items ADD COLUMN is_takeout boolean NOT NULL DEFAULT false;
ALTER TABLE public.emergency_order_queue ADD COLUMN workflow_version smallint NOT NULL DEFAULT 2,
 ADD CONSTRAINT pickup_queue_order_unique UNIQUE(session_id,order_id),
 ADD CONSTRAINT pickup_queue_number_unique UNIQUE(session_id,queue_no);
ALTER TABLE public.emergency_fulfillment_items
 ADD CONSTRAINT pickup_item_unique UNIQUE(session_id,order_item_id);
ALTER TABLE public.emergency_fulfillment_actions ADD COLUMN station_assignment_id uuid,
 ADD COLUMN session_id uuid, ADD COLUMN restaurant_id uuid, ADD COLUMN order_id uuid,
 ADD COLUMN floor_label text, ADD COLUMN stage text, ADD COLUMN actor_user_id uuid,
 ADD PRIMARY KEY(action_id);
ALTER TABLE public.emergency_fulfillment_events ADD COLUMN action_id uuid,
 ADD COLUMN leftover_packaging_request_id uuid, ADD COLUMN floor_direct_item_id uuid;
CREATE TABLE public.leftover_packaging_requests(id uuid,order_id uuid,queue_id uuid,
 table_number text,floor_label text,status text,requested_at timestamptz,updated_at timestamptz);
CREATE TABLE public.emergency_web_push_devices(id uuid PRIMARY KEY,station_assignment_id uuid,
 restaurant_id uuid,is_enabled boolean,token text);
CREATE TABLE public.emergency_push_deliveries(event_id uuid,restaurant_id uuid,device_id uuid,
 push_token text,station_type text,floor_label text,order_id uuid,stage text,
 UNIQUE(event_id,device_id));
INSERT INTO auth.users(id,email) VALUES
 ('00000000-0000-4000-8000-000000000003','fixture-tray@example.invalid'),
 ('00000000-0000-4000-8000-000000000004','fixture-floor@example.invalid');
-- Existing finance tests already created real cashier and kitchen actors.
INSERT INTO public.users(auth_id,role,is_active,restaurant_id) VALUES
 ('00000000-0000-4000-8000-000000000003','waiter',true,'d1000000-0000-4000-8000-000000000002'),
 ('00000000-0000-4000-8000-000000000004','waiter',true,'d1000000-0000-4000-8000-000000000002');
INSERT INTO public.emergency_station_assignments(restaurant_id,user_id,station_type,floor_label)
 SELECT restaurant_id,id,CASE WHEN auth_id='00000000-0000-4000-8000-000000000003' THEN 'tray' ELSE 'floor' END,
 CASE WHEN auth_id='00000000-0000-4000-8000-000000000004' THEN '1F' END FROM public.users
 WHERE auth_id IN ('00000000-0000-4000-8000-000000000003','00000000-0000-4000-8000-000000000004');
CREATE TABLE pickup_kds_test.stranded(request jsonb,approval jsonb,financial_hash text);
CREATE FUNCTION pickup_kds_test.financial_hash(p_order_id uuid) RETURNS text LANGUAGE sql AS $$
 SELECT md5(jsonb_build_object('order',(SELECT to_jsonb(o) FROM public.orders o WHERE o.id=p_order_id),
  'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM public.order_items i WHERE i.order_id=p_order_id),
  'payments',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM public.payments p WHERE p.order_id=p_order_id),
  'financial',(SELECT to_jsonb(f) FROM public.direct_order_financials f WHERE f.order_id=p_order_id),
  'inventory',(SELECT jsonb_agg(to_jsonb(i)) FROM public.inventory_items i))::text)
$$;
