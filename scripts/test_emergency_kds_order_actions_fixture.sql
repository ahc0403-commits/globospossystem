CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS auth;

CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT NULLIF(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

CREATE TABLE public.restaurants (id uuid PRIMARY KEY);
CREATE TABLE public.users (
  id uuid PRIMARY KEY,
  auth_id uuid NOT NULL,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE public.orders (id uuid PRIMARY KEY);
CREATE TABLE public.order_items (
  id uuid PRIMARY KEY,
  label text,
  display_name text,
  menu_item_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.menu_items (
  id uuid PRIMARY KEY,
  name text,
  name_vi text,
  name_en text
);
CREATE TABLE public.emergency_fulfillment_sessions (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  status text NOT NULL,
  activated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.emergency_station_assignments (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  user_id uuid NOT NULL REFERENCES public.users(id),
  station_type text NOT NULL,
  floor_label text,
  is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE public.emergency_order_queue (
  id uuid PRIMARY KEY,
  session_id uuid NOT NULL REFERENCES public.emergency_fulfillment_sessions(id),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  queue_no integer NOT NULL,
  table_number text NOT NULL,
  floor_label text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.emergency_fulfillment_items (
  id uuid PRIMARY KEY,
  session_id uuid NOT NULL REFERENCES public.emergency_fulfillment_sessions(id),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  queue_id uuid NOT NULL REFERENCES public.emergency_order_queue(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  order_item_id uuid NOT NULL REFERENCES public.order_items(id),
  source_quantity integer NOT NULL,
  ordered_quantity integer NOT NULL,
  kitchen_done_quantity integer NOT NULL DEFAULT 0,
  tray_received_quantity integer NOT NULL DEFAULT 0,
  tray_dispatched_quantity integer NOT NULL DEFAULT 0,
  floor_served_quantity integer NOT NULL DEFAULT 0,
  is_cancelled boolean NOT NULL DEFAULT false,
  needs_review boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fixture_quantity_chain CHECK (
    floor_served_quantity >= 0
    AND floor_served_quantity <= tray_dispatched_quantity
    AND tray_dispatched_quantity <= tray_received_quantity
    AND tray_received_quantity <= kitchen_done_quantity
    AND kitchen_done_quantity <= ordered_quantity
  )
);
CREATE TABLE public.emergency_fulfillment_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL UNIQUE,
  session_id uuid NOT NULL REFERENCES public.emergency_fulfillment_sessions(id),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  order_item_id uuid REFERENCES public.order_items(id),
  stage text NOT NULL,
  delta integer NOT NULL,
  actor_user_id uuid REFERENCES public.users(id),
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.is_super_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT false $$;

CREATE OR REPLACE FUNCTION public.user_accessible_stores(p_auth_id uuid)
RETURNS TABLE(store_id uuid)
LANGUAGE sql STABLE
AS $$
  SELECT restaurant_id FROM public.users WHERE auth_id = p_auth_id;
$$;

CREATE OR REPLACE FUNCTION public.emergency_enqueue_push(
  p_event_id uuid,
  p_store_id uuid,
  p_order_id uuid,
  p_target_station text,
  p_floor_label text,
  p_stage text
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM p_event_id, p_store_id, p_order_id, p_target_station,
    p_floor_label, p_stage;
END;
$$;

INSERT INTO public.restaurants (id)
VALUES ('00000000-0000-0000-0000-000000000001');
INSERT INTO public.users (id, auth_id, restaurant_id)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-000000000001'
);
INSERT INTO public.orders (id)
VALUES ('00000000-0000-0000-0000-000000000004');
INSERT INTO public.order_items (id, label)
VALUES ('00000000-0000-0000-0000-000000000005', 'Fixture item');
INSERT INTO public.emergency_fulfillment_sessions (
  id, restaurant_id, status
) VALUES (
  '00000000-0000-0000-0000-000000000006',
  '00000000-0000-0000-0000-000000000001',
  'active'
);
INSERT INTO public.emergency_station_assignments (
  id, restaurant_id, user_id, station_type
) VALUES (
  '00000000-0000-0000-0000-000000000007',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  'kitchen'
);
INSERT INTO public.emergency_order_queue (
  id, session_id, restaurant_id, order_id, queue_no,
  table_number, floor_label
) VALUES (
  '00000000-0000-0000-0000-000000000008',
  '00000000-0000-0000-0000-000000000006',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000004',
  1, '12', '2F'
);
INSERT INTO public.emergency_fulfillment_items (
  id, session_id, restaurant_id, queue_id, order_id, order_item_id,
  source_quantity, ordered_quantity
) VALUES (
  '00000000-0000-0000-0000-000000000009',
  '00000000-0000-0000-0000-000000000006',
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000008',
  '00000000-0000-0000-0000-000000000004',
  '00000000-0000-0000-0000-000000000005',
  2, 2
);

SELECT set_config(
  'request.jwt.claim.sub',
  '00000000-0000-0000-0000-000000000003',
  false
);
