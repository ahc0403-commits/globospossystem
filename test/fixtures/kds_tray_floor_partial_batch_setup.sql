CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
END;
$roles$;

CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE TABLE public.users (
  id uuid PRIMARY KEY,
  auth_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.emergency_station_assignments (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL,
  user_id uuid NOT NULL,
  station_type text NOT NULL,
  floor_label text,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.emergency_tray_floor_batch_actions (
  request_id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL,
  floor_label text NOT NULL,
  allocation_hash text NOT NULL,
  response jsonb NOT NULL,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.emergency_fulfillment_sessions (
  id uuid PRIMARY KEY,
  status text NOT NULL
);

CREATE TABLE public.orders (
  id uuid PRIMARY KEY,
  sales_channel text
);

CREATE TABLE public.emergency_order_queue (
  id uuid PRIMARY KEY,
  order_id uuid NOT NULL,
  floor_label text NOT NULL,
  workflow_version integer NOT NULL
);

CREATE TABLE public.emergency_fulfillment_items (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL,
  session_id uuid NOT NULL,
  queue_id uuid NOT NULL,
  order_id uuid NOT NULL,
  order_item_id uuid NOT NULL,
  kitchen_done_quantity integer NOT NULL DEFAULT 0,
  tray_received_quantity integer NOT NULL DEFAULT 0,
  tray_dispatched_quantity integer NOT NULL DEFAULT 0,
  is_cancelled boolean NOT NULL DEFAULT false,
  needs_review boolean NOT NULL DEFAULT false
);

CREATE TABLE public.emergency_combo_component_items (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL,
  session_id uuid NOT NULL,
  queue_id uuid NOT NULL,
  order_item_id uuid NOT NULL,
  kitchen_done_quantity integer NOT NULL DEFAULT 0,
  tray_received_quantity integer NOT NULL DEFAULT 0,
  tray_dispatched_quantity integer NOT NULL DEFAULT 0,
  is_cancelled boolean NOT NULL DEFAULT false,
  needs_review boolean NOT NULL DEFAULT false
);

CREATE TABLE public.emergency_tray_ready_sequences (
  restaurant_id uuid PRIMARY KEY,
  last_sequence bigint NOT NULL DEFAULT 0
);

CREATE TABLE public.test_kds_progress_events (
  event_id uuid PRIMARY KEY,
  source_kind text NOT NULL,
  source_id uuid NOT NULL,
  delta integer NOT NULL
);

CREATE FUNCTION public.kds_record_station_progress_v3(
  p_item_id uuid,
  p_source_kind text,
  p_action text,
  p_delta integer,
  p_event_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_changed integer;
BEGIN
  IF p_action <> 'tray_dispatched' OR p_delta <> 1 THEN
    RAISE EXCEPTION 'TEST_PROGRESS_INPUT_INVALID';
  END IF;
  IF p_source_kind = 'base' THEN
    UPDATE public.emergency_fulfillment_items
    SET tray_received_quantity = tray_received_quantity + p_delta,
        tray_dispatched_quantity = tray_dispatched_quantity + p_delta
    WHERE id = p_item_id
      AND tray_dispatched_quantity + p_delta <= kitchen_done_quantity;
  ELSIF p_source_kind = 'combo_component' THEN
    UPDATE public.emergency_combo_component_items
    SET tray_received_quantity = tray_received_quantity + p_delta,
        tray_dispatched_quantity = tray_dispatched_quantity + p_delta
    WHERE id = p_item_id
      AND tray_dispatched_quantity + p_delta <= kitchen_done_quantity;
  ELSE
    RAISE EXCEPTION 'TEST_PROGRESS_SOURCE_INVALID';
  END IF;
  GET DIAGNOSTICS v_changed = ROW_COUNT;
  IF v_changed <> 1 THEN
    RAISE EXCEPTION 'TEST_PROGRESS_STALE';
  END IF;
  INSERT INTO public.test_kds_progress_events(
    event_id, source_kind, source_id, delta
  ) VALUES (p_event_id, p_source_kind, p_item_id, p_delta);
  RETURN jsonb_build_object('event_id', p_event_id);
END;
$$;

CREATE FUNCTION public.kds_dispatch_tray_floor_batch_v1(
  p_request_id uuid,
  p_floor_label text,
  p_allocations jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_server_snapshot jsonb := '[]'::jsonb;
  v_client_snapshot jsonb := p_allocations;
BEGIN
  -- Baseline marker asserted by the production preflight.
  IF v_server_snapshot <> v_client_snapshot THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_BATCH_STALE';
  END IF;
  RETURN '{}'::jsonb;
END;
$$;

INSERT INTO public.users(id, auth_id, restaurant_id)
VALUES (
  '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000003'
);
INSERT INTO public.emergency_station_assignments(
  id, restaurant_id, user_id, station_type
) VALUES (
  '10000000-0000-0000-0000-000000000004',
  '10000000-0000-0000-0000-000000000003',
  '10000000-0000-0000-0000-000000000001',
  'tray'
);
INSERT INTO public.emergency_fulfillment_sessions(id, status)
VALUES ('10000000-0000-0000-0000-000000000005', 'active');
INSERT INTO public.orders(id, sales_channel)
VALUES ('10000000-0000-0000-0000-000000000006', 'dine_in');
INSERT INTO public.emergency_order_queue(
  id, order_id, floor_label, workflow_version
) VALUES (
  '10000000-0000-0000-0000-000000000007',
  '10000000-0000-0000-0000-000000000006',
  '1F', 2
);
INSERT INTO public.emergency_fulfillment_items(
  id, restaurant_id, session_id, queue_id, order_id, order_item_id,
  kitchen_done_quantity
) VALUES
  (
    '10000000-0000-0000-0000-000000000008',
    '10000000-0000-0000-0000-000000000003',
    '10000000-0000-0000-0000-000000000005',
    '10000000-0000-0000-0000-000000000007',
    '10000000-0000-0000-0000-000000000006',
    '10000000-0000-0000-0000-000000000009',
    2
  ),
  (
    '10000000-0000-0000-0000-000000000010',
    '10000000-0000-0000-0000-000000000003',
    '10000000-0000-0000-0000-000000000005',
    '10000000-0000-0000-0000-000000000007',
    '10000000-0000-0000-0000-000000000006',
    '10000000-0000-0000-0000-000000000011',
    1
  );
INSERT INTO public.emergency_tray_ready_sequences(restaurant_id)
VALUES ('10000000-0000-0000-0000-000000000003');
