CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS realtime;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT NULL::uuid $$;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
END $$;
CREATE TABLE public.restaurants(id uuid PRIMARY KEY);
CREATE TABLE public.users(id uuid PRIMARY KEY,auth_id uuid,is_active boolean,restaurant_id uuid);
CREATE TABLE public.emergency_fulfillment_sessions(id uuid PRIMARY KEY,restaurant_id uuid,status text);
CREATE TABLE public.orders(id uuid PRIMARY KEY,restaurant_id uuid,sales_channel text);
CREATE TABLE public.menu_items(id uuid PRIMARY KEY,paperless_name_vi text);
CREATE TABLE public.order_items(id uuid PRIMARY KEY,menu_item_id uuid);
CREATE TABLE public.emergency_floor_direct_items(id uuid PRIMARY KEY,component_menu_item_id uuid);
CREATE TABLE public.emergency_combo_component_items(id uuid PRIMARY KEY,queue_id uuid,order_item_id uuid,line_key text,name_ko text,name_vi text,name_en text,component_menu_item_id uuid,
 ordered_quantity int,kitchen_done_quantity int,tray_received_quantity int,tray_dispatched_quantity int,floor_served_quantity int,needs_review boolean,is_cancelled boolean,created_at timestamptz);
CREATE TABLE public.emergency_order_queue(id uuid PRIMARY KEY,session_id uuid,restaurant_id uuid,order_id uuid,floor_label text,queue_no int);
CREATE TABLE public.emergency_fulfillment_actions(action_id uuid PRIMARY KEY,station_type text,action_kind text);
CREATE TABLE public.emergency_station_assignments(restaurant_id uuid,station_type text,is_active boolean);
CREATE TABLE public.leftover_packaging_requests(id uuid PRIMARY KEY,order_id uuid,queue_id uuid,table_number text,floor_label text,status text,requested_at timestamptz,updated_at timestamptz);
CREATE TABLE public.emergency_fulfillment_events(id uuid DEFAULT gen_random_uuid(),event_id uuid DEFAULT gen_random_uuid(),session_id uuid,restaurant_id uuid,order_id uuid,order_item_id uuid,stage text,delta int,action_id uuid,details jsonb DEFAULT '{}',leftover_packaging_request_id uuid);
CREATE TABLE public.audit_logs(actor_id uuid,action text,entity_type text,entity_id uuid,details jsonb);
CREATE TABLE realtime.kds_lab_messages(topic text,payload jsonb);
CREATE FUNCTION realtime.send(payload jsonb,event text,topic text,private boolean) RETURNS void LANGUAGE sql AS $$ INSERT INTO realtime.kds_lab_messages VALUES(topic,payload) $$;
