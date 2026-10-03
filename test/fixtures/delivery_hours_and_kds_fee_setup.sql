-- Unrelated notification delivery is reduced; real routing, ledger trigger,
-- station reads, progress, submit, photo approval and payment SQL are loaded.
DO $$ BEGIN
 IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
END $$;
CREATE SCHEMA hours_test;
ALTER TABLE public.direct_order_request_addresses
 ALTER COLUMN latitude DROP NOT NULL, ALTER COLUMN longitude DROP NOT NULL;
ALTER TABLE public.direct_order_request_addresses
 DROP CONSTRAINT direct_order_request_addresses_address_source_check,
 ADD CONSTRAINT direct_order_request_addresses_address_source_check
 CHECK (address_source IN ('manual','search','map_pin')),
 ADD CONSTRAINT direct_order_address_location_mode_valid CHECK (
 (address_source='manual' AND latitude IS NULL AND longitude IS NULL AND google_place_id IS NULL AND NOT location_verified)
 OR (address_source IN ('search','map_pin') AND latitude IS NOT NULL AND longitude IS NOT NULL));
ALTER TABLE public.direct_order_storefronts ADD COLUMN ordering_hours_enforced boolean DEFAULT false NOT NULL;
DO $$ DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure) INTO d;
 EXECUTE replace(d,
  '  IF v_local_time >= LEAST(v_storefront.ordering_cutoff_at, ''21:30''::time) THEN',
  E'  IF v_storefront.ordering_hours_enforced\n     AND v_local_time >= LEAST(v_storefront.ordering_cutoff_at, ''21:30''::time) THEN');
END $$;
ALTER TABLE public.menu_items ADD COLUMN is_combo boolean DEFAULT false,
 ADD COLUMN fulfillment_route text DEFAULT 'kitchen_tray_floor',
 ADD COLUMN combo_drink_choice_count integer DEFAULT 0,
 ADD COLUMN category_id uuid, ADD COLUMN description text, ADD COLUMN image_url text,
 ADD COLUMN sort_order integer DEFAULT 0;
ALTER TABLE public.order_items ADD COLUMN fulfillment_route_snapshot text DEFAULT 'kitchen_tray_floor',
 ADD COLUMN combo_components jsonb DEFAULT '[]';
ALTER TABLE public.tables ADD COLUMN table_number text, ADD COLUMN floor_label text;
ALTER TABLE public.restaurants ADD COLUMN name text DEFAULT 'Fixture', ADD COLUMN is_active boolean DEFAULT true;
ALTER TABLE public.restaurant_settings ADD COLUMN floor_direct_beverages_enabled boolean DEFAULT false;
ALTER TABLE public.emergency_fulfillment_sessions ADD COLUMN id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 ADD COLUMN activated_at timestamptz DEFAULT now();
CREATE TABLE public.menu_categories(id uuid,restaurant_id uuid,name text,name_ko text,name_vi text,name_en text,sort_order integer,is_active boolean);
CREATE TABLE public.emergency_station_assignments(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 restaurant_id uuid,user_id uuid,station_type text,floor_label text,is_active boolean DEFAULT true);
CREATE TABLE public.emergency_order_queue(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 session_id uuid,restaurant_id uuid,order_id uuid,queue_no integer,table_number text,floor_label text,
 created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now());
CREATE TABLE public.emergency_fulfillment_items(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 session_id uuid,restaurant_id uuid,queue_id uuid,order_id uuid,order_item_id uuid,
 source_quantity integer,ordered_quantity integer,kitchen_done_quantity integer DEFAULT 0,
 tray_received_quantity integer DEFAULT 0,tray_dispatched_quantity integer DEFAULT 0,
 floor_served_quantity integer DEFAULT 0,is_cancelled boolean DEFAULT false,needs_review boolean DEFAULT false,
 created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now());
CREATE TABLE public.emergency_floor_direct_items(id uuid,session_id uuid,order_item_id uuid,source_kind text,
 is_cancelled boolean,updated_at timestamptz,queue_id uuid,created_at timestamptz,line_key text,name_ko text,
 name_vi text,name_en text,ordered_quantity integer,floor_served_quantity integer,needs_review boolean);
CREATE TABLE public.emergency_fulfillment_events(id uuid DEFAULT gen_random_uuid(),event_id uuid,
 session_id uuid,restaurant_id uuid,order_id uuid,order_item_id uuid,stage text,delta integer,
 actor_user_id uuid,details jsonb,created_at timestamptz DEFAULT now());
CREATE TABLE public.emergency_fulfillment_actions(action_id uuid,queue_id uuid,station_type text,
 action_kind text,original_action_id uuid,created_at timestamptz);
CREATE FUNCTION public.emergency_enqueue_push(uuid,uuid,uuid,text,text,text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN END $$;
INSERT INTO public.emergency_fulfillment_sessions(restaurant_id,status)
VALUES('d1000000-0000-4000-8000-000000000002','active');
INSERT INTO public.emergency_station_assignments(restaurant_id,user_id,station_type)
SELECT restaurant_id,id,'kitchen' FROM public.users WHERE role='kitchen';
UPDATE public.restaurant_settings SET fulfillment_mode='paperless';

CREATE FUNCTION hours_test.new_order() RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_order uuid;
BEGIN
 INSERT INTO public.orders(restaurant_id,sales_channel,status)
 VALUES('d1000000-0000-4000-8000-000000000002','delivery','serving') RETURNING id INTO v_order;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,unit_price,quantity,status,label)
 SELECT 'd1000000-0000-4000-8000-000000000002',v_order,'d1000000-0000-4000-8000-000000000003','menu_item',100000,1,'served','Food'
 FROM generate_series(1,6);
 INSERT INTO public.order_items(restaurant_id,order_id,item_type,unit_price,quantity,status,label)
 VALUES('d1000000-0000-4000-8000-000000000002',v_order,'service_charge',0,1,'served','Phí giao hàng'),
 ('d1000000-0000-4000-8000-000000000002',v_order,'service_charge',25000,1,'served','Phí giao hàng');
 RETURN v_order;
END $$;
CREATE TABLE hours_test.legacy_order(order_id uuid,financial_hash text);
