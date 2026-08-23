BEGIN;

-- production-gate: self-verifying

-- A takeout choice changes preparation/presentation only. It must remain an
-- immutable order-line snapshot and must not overload the station route or
-- order-purpose contracts.
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS is_takeout boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.order_items.is_takeout IS
  'Order-time menu-line choice: true for takeout, false for dine-in.';

-- The existing mutation RPCs are authoritative and contain substantial
-- pricing, promotion, printing, inventory, and idempotency behavior. Preserve
-- those bodies and wrap them with a transaction-local payload consumed by the
-- additive snapshot trigger below.
ALTER FUNCTION public.create_order(uuid, uuid, jsonb)
  RENAME TO create_order_pre_takeout_core;
ALTER FUNCTION public.add_items_to_order(uuid, uuid, jsonb)
  RENAME TO add_items_to_order_pre_takeout_core;
ALTER FUNCTION public.qr_place_order(text, jsonb, uuid)
  RENAME TO qr_place_order_pre_takeout_core;

CREATE OR REPLACE FUNCTION public.snapshot_order_item_takeout()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_payload_text text;
  v_payload jsonb;
  v_selected jsonb;
  v_selected_ordinal bigint;
  v_remaining jsonb;
BEGIN
  v_payload_text := current_setting('pos.order_takeout_payload', true);
  IF NULLIF(v_payload_text, '') IS NULL THEN
    RETURN NEW;
  END IF;

  v_payload := v_payload_text::jsonb;
  SELECT line.raw, line.ord
  INTO v_selected, v_selected_ordinal
  FROM jsonb_array_elements(v_payload)
    WITH ORDINALITY AS line(raw, ord)
  WHERE line.raw->>'menu_item_id' = NEW.menu_item_id::text
    AND COALESCE((line.raw->>'quantity')::integer, 0) = NEW.quantity
  ORDER BY line.ord
  LIMIT 1;

  IF v_selected IS NULL THEN
    SELECT line.raw, line.ord
    INTO v_selected, v_selected_ordinal
    FROM jsonb_array_elements(v_payload)
      WITH ORDINALITY AS line(raw, ord)
    WHERE line.raw->>'menu_item_id' = NEW.menu_item_id::text
    ORDER BY line.ord
    LIMIT 1;
  END IF;

  IF v_selected IS NOT NULL THEN
    NEW.is_takeout := COALESCE((v_selected->>'is_takeout')::boolean, false);
    SELECT COALESCE(jsonb_agg(line.raw ORDER BY line.ord), '[]'::jsonb)
    INTO v_remaining
    FROM jsonb_array_elements(v_payload)
      WITH ORDINALITY AS line(raw, ord)
    WHERE line.ord <> v_selected_ordinal;
    PERFORM set_config('pos.order_takeout_payload', v_remaining::text, true);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS aa_snapshot_order_item_takeout_trigger
  ON public.order_items;
CREATE TRIGGER aa_snapshot_order_item_takeout_trigger
BEFORE INSERT ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.snapshot_order_item_takeout();

-- The takeout trigger runs before this existing combo snapshot trigger. Use
-- the line choice to select the correct QR combo payload when the same menu is
-- ordered once for dine-in and once for takeout.
CREATE OR REPLACE FUNCTION public.snapshot_order_item_combo_components()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO public
AS $$
DECLARE
  v_payload_text text;
  v_selected jsonb := '[]'::jsonb;
  v_fixed jsonb := '[]'::jsonb;
  v_drinks jsonb := '[]'::jsonb;
BEGIN
  IF NEW.menu_item_id IS NULL THEN
    NEW.combo_components := '[]'::jsonb;
    RETURN NEW;
  END IF;

  v_payload_text := current_setting('pos.qr_combo_payload', true);
  IF NULLIF(v_payload_text, '') IS NOT NULL THEN
    SELECT COALESCE(line.raw->'combo_drink_choices', '[]'::jsonb)
    INTO v_selected
    FROM jsonb_array_elements(v_payload_text::jsonb) line(raw)
    WHERE line.raw->>'menu_item_id' = NEW.menu_item_id::text
      AND COALESCE((line.raw->>'is_takeout')::boolean, false) = NEW.is_takeout
    LIMIT 1;
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'menu_item_id', component_item.id::text,
      'label', component_item.name,
      'quantity', component.quantity
    ) ORDER BY component.sort_order, component.created_at, component.id
  ), '[]'::jsonb)
  INTO v_fixed
  FROM public.menu_combo_components component
  JOIN public.menu_items component_item
    ON component_item.id = component.component_menu_item_id
   AND component_item.restaurant_id = component.restaurant_id
  WHERE component.combo_menu_item_id = NEW.menu_item_id
    AND component.restaurant_id = NEW.restaurant_id
    AND (
      jsonb_array_length(v_selected) = 0
      OR lower(btrim(COALESCE(NULLIF(component_item.name_ko, ''), component_item.name)))
        NOT IN ('음료', 'drink', 'beverage', 'đồ uống', 'nước uống')
    );

  IF jsonb_array_length(v_selected) > 0 THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'menu_item_id', selected_item.id::text,
      'label', selected_item.name,
      'quantity', selected.quantity,
      'is_total_quantity', true
    ) ORDER BY selected.first_ordinal), '[]'::jsonb)
    INTO v_drinks
    FROM (
      SELECT choice.value::uuid AS item_id,
             count(*)::integer AS quantity,
             min(choice.ordinality) AS first_ordinal
      FROM jsonb_array_elements_text(v_selected)
        WITH ORDINALITY choice(value, ordinality)
      GROUP BY choice.value
    ) selected
    JOIN public.menu_items selected_item ON selected_item.id = selected.item_id;
  END IF;

  NEW.combo_components := v_fixed || v_drinks;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_order(
  p_store_id uuid,
  p_table_id uuid,
  p_items jsonb
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_result public.orders%ROWTYPE;
BEGIN
  IF jsonb_typeof(p_items) <> 'array'
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_items) line(raw)
       WHERE line.raw ? 'is_takeout'
         AND jsonb_typeof(line.raw->'is_takeout') <> 'boolean'
     ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;
  PERFORM set_config('pos.order_takeout_payload', p_items::text, true);
  v_result := public.create_order_pre_takeout_core(
    p_store_id, p_table_id, p_items
  );
  PERFORM set_config('pos.order_takeout_payload', '', true);
  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('pos.order_takeout_payload', '', true);
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.add_items_to_order(
  p_order_id uuid,
  p_store_id uuid,
  p_items jsonb
) RETURNS SETOF public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
BEGIN
  IF jsonb_typeof(p_items) <> 'array'
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_items) line(raw)
       WHERE line.raw ? 'is_takeout'
         AND jsonb_typeof(line.raw->'is_takeout') <> 'boolean'
     ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;
  PERFORM set_config('pos.order_takeout_payload', p_items::text, true);
  RETURN QUERY
  SELECT * FROM public.add_items_to_order_pre_takeout_core(
    p_order_id, p_store_id, p_items
  );
  PERFORM set_config('pos.order_takeout_payload', '', true);
  RETURN;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('pos.order_takeout_payload', '', true);
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.qr_place_order(
  p_token text,
  p_items jsonb,
  p_client_order_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF jsonb_typeof(p_items) <> 'array'
     OR EXISTS (
       SELECT 1 FROM jsonb_array_elements(p_items) line(raw)
       WHERE line.raw ? 'is_takeout'
         AND jsonb_typeof(line.raw->'is_takeout') <> 'boolean'
     ) THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;
  PERFORM set_config('pos.order_takeout_payload', p_items::text, true);
  v_result := public.qr_place_order_pre_takeout_core(
    p_token, p_items, p_client_order_id
  );
  PERFORM set_config('pos.order_takeout_payload', '', true);
  RETURN v_result;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('pos.order_takeout_payload', '', true);
  RAISE;
END;
$$;

-- Preserve the current combo validation while allowing one dine-in and one
-- takeout line for the same menu in a batch.
CREATE OR REPLACE FUNCTION public.qr_place_order(
  p_token text,
  p_items jsonb,
  p_client_order_id uuid,
  p_validate_combo_choices boolean
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_items jsonb := COALESCE(p_items, '[]'::jsonb);
  v_table record;
  v_existing public.qr_order_batches%ROWTYPE;
  v_line record;
  v_choice_count integer;
  v_expected_count integer;
BEGIN
  IF p_client_order_id IS NULL OR jsonb_typeof(v_items) <> 'array' THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  IF (
    SELECT count(*)
    FROM (
      SELECT line.raw->>'menu_item_id',
             COALESCE((line.raw->>'is_takeout')::boolean, false)
      FROM jsonb_array_elements(v_items) line(raw)
      GROUP BY line.raw->>'menu_item_id',
               COALESCE((line.raw->>'is_takeout')::boolean, false)
    ) unique_lines
  ) <> jsonb_array_length(v_items) THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  SELECT q.restaurant_id, q.table_id
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t ON t.id = q.table_id AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r ON r.id = q.restaurant_id AND r.is_active = true
  WHERE q.token = v_token AND q.is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;

  SELECT * INTO v_existing
  FROM public.qr_order_batches
  WHERE client_order_id = p_client_order_id
    AND restaurant_id = v_table.restaurant_id
    AND table_id = v_table.table_id;
  IF FOUND THEN RETURN v_existing.result_snapshot; END IF;

  FOR v_line IN SELECT raw FROM jsonb_array_elements(v_items) line(raw)
  LOOP
    IF COALESCE(v_line.raw->>'menu_item_id', '')
         !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR COALESCE(v_line.raw->>'quantity', '') !~ '^[0-9]+$'
       OR (v_line.raw ? 'is_takeout'
         AND jsonb_typeof(v_line.raw->'is_takeout') <> 'boolean') THEN
      RAISE EXCEPTION 'QR_ITEMS_INVALID';
    END IF;

    IF jsonb_typeof(COALESCE(v_line.raw->'combo_drink_choices', '[]'::jsonb))
         <> 'array' THEN
      RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
    END IF;

    v_choice_count := jsonb_array_length(
      COALESCE(v_line.raw->'combo_drink_choices', '[]'::jsonb)
    );
    v_expected_count := public.combo_drink_choice_count(
      (v_line.raw->>'menu_item_id')::uuid
    ) * (v_line.raw->>'quantity')::integer;

    IF v_choice_count <> v_expected_count THEN
      RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
    END IF;

    IF v_choice_count > 0 AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(v_line.raw->'combo_drink_choices') choice(value)
      LEFT JOIN public.menu_items option_item
        ON option_item.id = CASE
             WHEN choice.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
             THEN choice.value::uuid ELSE NULL
           END
       AND option_item.restaurant_id = v_table.restaurant_id
       AND option_item.is_archived = false
       AND option_item.is_available = true
       AND option_item.is_visible_public = true
       AND option_item.is_combo = false
      LEFT JOIN public.menu_categories drink_category
        ON drink_category.id = option_item.category_id
       AND drink_category.restaurant_id = v_table.restaurant_id
       AND drink_category.system_key = 'drink'
       AND drink_category.is_active = true
      WHERE option_item.id IS NULL OR drink_category.id IS NULL
    ) THEN
      RAISE EXCEPTION 'QR_COMBO_DRINK_CHOICES_INVALID';
    END IF;
  END LOOP;

  PERFORM set_config('pos.qr_combo_payload', v_items::text, true);
  RETURN public.qr_place_order(p_token, p_items, p_client_order_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_order_pre_takeout_core(uuid, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.add_items_to_order_pre_takeout_core(uuid, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_place_order_pre_takeout_core(text, jsonb, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_order(uuid, uuid, jsonb)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.add_items_to_order(uuid, uuid, jsonb)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.qr_place_order(text, jsonb, uuid)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.qr_place_order(text, jsonb, uuid, boolean)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_order(uuid, uuid, jsonb),
  public.add_items_to_order(uuid, uuid, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.qr_place_order(text, jsonb, uuid),
  public.qr_place_order(text, jsonb, uuid, boolean)
  TO anon, authenticated, service_role;

-- Leftover packaging is an operational round trip, not a sale line.
CREATE TABLE public.leftover_packaging_requests (
  id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  session_id uuid NOT NULL
    REFERENCES public.emergency_fulfillment_sessions(id) ON DELETE CASCADE,
  queue_id uuid NOT NULL
    REFERENCES public.emergency_order_queue(id) ON DELETE CASCADE,
  table_number text NOT NULL,
  floor_label text NOT NULL,
  source text NOT NULL CHECK (source IN ('qr', 'staff')),
  status text NOT NULL DEFAULT 'awaiting_floor_pickup' CHECK (status IN (
    'awaiting_floor_pickup',
    'awaiting_tray_to_kitchen',
    'awaiting_kitchen_packaging',
    'awaiting_tray_return',
    'awaiting_floor_delivery',
    'completed',
    'cancelled'
  )),
  requested_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  requested_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  UNIQUE (order_id)
);

CREATE INDEX leftover_packaging_station_queue_idx
  ON public.leftover_packaging_requests
  (session_id, status, floor_label, requested_at);

ALTER TABLE public.leftover_packaging_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY leftover_packaging_store_read
ON public.leftover_packaging_requests
FOR SELECT TO authenticated
USING (public.is_super_admin() OR EXISTS (
  SELECT 1 FROM public.user_accessible_stores((SELECT auth.uid())) scope(store_id)
  WHERE scope.store_id = restaurant_id
));
REVOKE ALL ON public.leftover_packaging_requests
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.leftover_packaging_requests TO authenticated;
GRANT ALL ON public.leftover_packaging_requests TO service_role;

ALTER TABLE public.emergency_fulfillment_events
  DROP CONSTRAINT IF EXISTS emergency_fulfillment_events_stage_check;
ALTER TABLE public.emergency_fulfillment_events
  ADD CONSTRAINT emergency_fulfillment_events_stage_check CHECK (stage IN (
    'order_received', 'floor_direct_ready', 'kitchen_done', 'tray_received',
    'tray_dispatched', 'floor_served',
    'leftover_requested', 'leftover_floor_to_tray',
    'leftover_tray_to_kitchen', 'leftover_kitchen_packaged',
    'leftover_tray_to_floor', 'leftover_floor_delivered'
  ));
ALTER TABLE public.emergency_fulfillment_events
  ADD COLUMN IF NOT EXISTS leftover_packaging_request_id uuid
    REFERENCES public.leftover_packaging_requests(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS emergency_events_leftover_request_idx
  ON public.emergency_fulfillment_events(leftover_packaging_request_id)
  WHERE leftover_packaging_request_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.create_leftover_packaging_request_core(
  p_order_id uuid,
  p_store_id uuid,
  p_request_id uuid,
  p_source text,
  p_actor_user_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_existing public.leftover_packaging_requests%ROWTYPE;
  v_created public.leftover_packaging_requests%ROWTYPE;
BEGIN
  IF p_request_id IS NULL OR p_source NOT IN ('qr', 'staff') THEN
    RAISE EXCEPTION 'LEFTOVER_PACKAGING_INPUT_INVALID';
  END IF;

  SELECT * INTO v_existing
  FROM public.leftover_packaging_requests
  WHERE id = p_request_id OR order_id = p_order_id
  ORDER BY (id = p_request_id) DESC
  LIMIT 1;
  IF FOUND THEN
    IF v_existing.id = p_request_id
       AND (v_existing.order_id <> p_order_id
         OR v_existing.restaurant_id <> p_store_id) THEN
      RAISE EXCEPTION 'LEFTOVER_PACKAGING_REQUEST_CONFLICT';
    END IF;
    RETURN jsonb_build_object(
      'request_id', v_existing.id,
      'status', v_existing.status,
      'deduplicated', true
    );
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
    AND status IN ('pending', 'confirmed', 'serving')
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LEFTOVER_PACKAGING_ORDER_UNAVAILABLE'; END IF;

  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = p_store_id AND status = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LEFTOVER_PACKAGING_PAPERLESS_REQUIRED'; END IF;

  SELECT * INTO v_queue
  FROM public.emergency_order_queue
  WHERE session_id = v_session.id AND order_id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'LEFTOVER_PACKAGING_QUEUE_UNAVAILABLE'; END IF;

  INSERT INTO public.leftover_packaging_requests(
    id, restaurant_id, order_id, session_id, queue_id,
    table_number, floor_label, source, requested_by
  ) VALUES (
    p_request_id, p_store_id, p_order_id, v_session.id, v_queue.id,
    v_queue.table_number, v_queue.floor_label, p_source, p_actor_user_id
  ) RETURNING * INTO v_created;

  INSERT INTO public.emergency_fulfillment_events(
    event_id, session_id, restaurant_id, order_id,
    leftover_packaging_request_id, stage, delta, actor_user_id, details
  ) VALUES (
    p_request_id, v_session.id, p_store_id, p_order_id,
    p_request_id, 'leftover_requested', 1, p_actor_user_id,
    jsonb_build_object('queue_id', v_queue.id, 'floor_label', v_queue.floor_label)
  );
  PERFORM public.emergency_enqueue_push(
    p_request_id, p_store_id, p_order_id,
    'floor', v_queue.floor_label, 'leftover_requested'
  );

  RETURN jsonb_build_object(
    'request_id', v_created.id,
    'status', v_created.status,
    'deduplicated', false
  );
EXCEPTION WHEN unique_violation THEN
  SELECT * INTO v_existing
  FROM public.leftover_packaging_requests
  WHERE id = p_request_id OR order_id = p_order_id
  ORDER BY (id = p_request_id) DESC
  LIMIT 1;
  IF FOUND THEN
    IF v_existing.id = p_request_id
       AND (v_existing.order_id <> p_order_id
         OR v_existing.restaurant_id <> p_store_id) THEN
      RAISE EXCEPTION 'LEFTOVER_PACKAGING_REQUEST_CONFLICT';
    END IF;
    RETURN jsonb_build_object(
      'request_id', v_existing.id,
      'status', v_existing.status,
      'deduplicated', true
    );
  END IF;
  RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.request_leftover_packaging(
  p_order_id uuid,
  p_store_id uuid,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
BEGIN
  SELECT * INTO v_user
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND OR v_user.role NOT IN (
    'waiter', 'cashier', 'admin', 'store_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'LEFTOVER_PACKAGING_FORBIDDEN';
  END IF;
  IF NOT public.is_super_admin() AND NOT EXISTS (
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'LEFTOVER_PACKAGING_FORBIDDEN';
  END IF;
  RETURN public.create_leftover_packaging_request_core(
    p_order_id, p_store_id, p_request_id, 'staff', v_user.id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.qr_request_leftover_packaging(
  p_token text,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_order public.orders%ROWTYPE;
BEGIN
  SELECT q.restaurant_id, q.table_id
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t ON t.id = q.table_id AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r ON r.id = q.restaurant_id AND r.is_active = true
  WHERE q.token = v_token AND q.is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE restaurant_id = v_table.restaurant_id
    AND table_id = v_table.table_id
    AND status IN ('pending', 'confirmed', 'serving')
  ORDER BY created_at DESC
  LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'LEFTOVER_PACKAGING_ORDER_UNAVAILABLE'; END IF;

  RETURN public.create_leftover_packaging_request_core(
    v_order.id, v_table.restaurant_id, p_request_id, 'qr', NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.emergency_advance_leftover_packaging(
  p_request_id uuid,
  p_event_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_request public.leftover_packaging_requests%ROWTYPE;
  v_existing public.emergency_fulfillment_events%ROWTYPE;
  v_required_station text;
  v_next_status text;
  v_stage text;
  v_target_station text;
BEGIN
  IF p_request_id IS NULL OR p_event_id IS NULL THEN
    RAISE EXCEPTION 'LEFTOVER_PACKAGING_INPUT_INVALID';
  END IF;
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_STATION_REQUIRED'; END IF;

  SELECT * INTO v_existing
  FROM public.emergency_fulfillment_events
  WHERE event_id = p_event_id;
  IF FOUND THEN
    IF v_existing.leftover_packaging_request_id IS DISTINCT FROM p_request_id THEN
      RAISE EXCEPTION 'LEFTOVER_PACKAGING_EVENT_CONFLICT';
    END IF;
    SELECT * INTO v_request FROM public.leftover_packaging_requests
    WHERE id = p_request_id;
    RETURN jsonb_build_object(
      'request_id', p_request_id,
      'status', v_request.status,
      'deduplicated', true
    );
  END IF;

  SELECT request.* INTO v_request
  FROM public.leftover_packaging_requests request
  JOIN public.emergency_fulfillment_sessions session
    ON session.id = request.session_id AND session.status = 'active'
  WHERE request.id = p_request_id
  FOR UPDATE OF request;
  IF NOT FOUND OR v_request.restaurant_id <> v_assignment.restaurant_id THEN
    RAISE EXCEPTION 'LEFTOVER_PACKAGING_UNAVAILABLE';
  END IF;

  SELECT required_station, next_status, stage, target_station
  INTO v_required_station, v_next_status, v_stage, v_target_station
  FROM (VALUES
    ('awaiting_floor_pickup', 'floor', 'awaiting_tray_to_kitchen',
      'leftover_floor_to_tray', 'tray'),
    ('awaiting_tray_to_kitchen', 'tray', 'awaiting_kitchen_packaging',
      'leftover_tray_to_kitchen', 'kitchen'),
    ('awaiting_kitchen_packaging', 'kitchen', 'awaiting_tray_return',
      'leftover_kitchen_packaged', 'tray'),
    ('awaiting_tray_return', 'tray', 'awaiting_floor_delivery',
      'leftover_tray_to_floor', 'floor'),
    ('awaiting_floor_delivery', 'floor', 'completed',
      'leftover_floor_delivered', NULL::text)
  ) transition(current_status, required_station, next_status, stage, target_station)
  WHERE current_status = v_request.status;

  IF v_required_station IS NULL THEN
    RAISE EXCEPTION 'LEFTOVER_PACKAGING_ALREADY_COMPLETE';
  END IF;
  IF v_assignment.station_type <> v_required_station
     OR (v_required_station = 'floor'
       AND v_assignment.floor_label <> v_request.floor_label) THEN
    RAISE EXCEPTION 'LEFTOVER_PACKAGING_STAGE_FORBIDDEN';
  END IF;

  UPDATE public.leftover_packaging_requests
  SET status = v_next_status,
      updated_at = now(),
      completed_at = CASE WHEN v_next_status = 'completed' THEN now() ELSE NULL END
  WHERE id = p_request_id;

  INSERT INTO public.emergency_fulfillment_events(
    event_id, session_id, restaurant_id, order_id,
    leftover_packaging_request_id, stage, delta, actor_user_id, details
  ) VALUES (
    p_event_id, v_request.session_id, v_request.restaurant_id,
    v_request.order_id, p_request_id, v_stage, 1, v_user.id,
    jsonb_build_object('from_status', v_request.status, 'to_status', v_next_status)
  );

  IF v_target_station IS NOT NULL THEN
    PERFORM public.emergency_enqueue_push(
      p_event_id, v_request.restaurant_id, v_request.order_id,
      v_target_station, v_request.floor_label, v_stage
    );
  END IF;

  RETURN jsonb_build_object(
    'request_id', p_request_id,
    'status', v_next_status,
    'deduplicated', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.qr_get_leftover_packaging_status(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_order public.orders%ROWTYPE;
  v_request public.leftover_packaging_requests%ROWTYPE;
BEGIN
  SELECT q.restaurant_id, q.table_id
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t ON t.id = q.table_id AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r ON r.id = q.restaurant_id AND r.is_active = true
  WHERE q.token = v_token AND q.is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;
  SELECT * INTO v_order FROM public.orders
  WHERE restaurant_id = v_table.restaurant_id
    AND table_id = v_table.table_id
    AND status IN ('pending', 'confirmed', 'serving')
  ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', NULL); END IF;
  SELECT * INTO v_request FROM public.leftover_packaging_requests
  WHERE order_id = v_order.id;
  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'status', v_request.status
  );
END;
$$;

-- Attach takeout flags and only the task currently actionable at the signed-in
-- station to the existing effective paperless snapshot.
ALTER FUNCTION public.get_emergency_station_snapshot()
  RENAME TO get_emergency_station_snapshot_pre_takeout_packaging;
ALTER FUNCTION public.get_emergency_station_today_completed()
  RENAME TO get_emergency_station_today_completed_pre_takeout;

CREATE OR REPLACE FUNCTION public.emergency_add_takeout_flags(p_orders jsonb)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO public, pg_catalog
AS $$
  SELECT COALESCE(jsonb_agg(
    order_row.raw || jsonb_build_object(
      'items', COALESCE((
        SELECT jsonb_agg(
          item_row.raw || jsonb_build_object(
            'is_takeout', COALESCE(order_item.is_takeout, false)
          ) ORDER BY item_row.ord
        )
        FROM jsonb_array_elements(COALESCE(order_row.raw->'items', '[]'::jsonb))
          WITH ORDINALITY item_row(raw, ord)
        LEFT JOIN public.order_items order_item
          ON order_item.id = CASE
            WHEN item_row.raw->>'order_item_id' ~*
              '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            THEN (item_row.raw->>'order_item_id')::uuid ELSE NULL END
      ), '[]'::jsonb)
    ) ORDER BY order_row.ord
  ), '[]'::jsonb)
  FROM jsonb_array_elements(COALESCE(p_orders, '[]'::jsonb))
    WITH ORDINALITY order_row(raw, ord);
$$;

CREATE OR REPLACE FUNCTION public.get_emergency_station_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_payload jsonb;
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_tasks jsonb := '[]'::jsonb;
BEGIN
  v_payload := public.get_emergency_station_snapshot_pre_takeout_packaging();
  IF jsonb_typeof(v_payload) = 'object' AND v_payload ? 'orders' THEN
    v_payload := jsonb_set(
      v_payload, '{orders}',
      public.emergency_add_takeout_flags(v_payload->'orders'), true
    );
  END IF;

  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF FOUND THEN
    SELECT * INTO v_assignment
    FROM public.emergency_station_assignments
    WHERE user_id = v_user.id
      AND is_active = true;
  END IF;

  IF v_assignment.id IS NOT NULL AND v_payload->>'session_id' IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', request.id,
      'order_id', request.order_id,
      'queue_id', request.queue_id,
      'queue_no', queue.queue_no,
      'table_number', request.table_number,
      'floor_label', request.floor_label,
      'status', request.status,
      'requested_at', request.requested_at,
      'updated_at', request.updated_at
    ) ORDER BY request.requested_at, request.id), '[]'::jsonb)
    INTO v_tasks
    FROM public.leftover_packaging_requests request
    JOIN public.emergency_order_queue queue ON queue.id = request.queue_id
    WHERE request.session_id = (v_payload->>'session_id')::uuid
      AND (
        (v_assignment.station_type = 'floor'
          AND request.floor_label = v_assignment.floor_label
          AND request.status IN ('awaiting_floor_pickup', 'awaiting_floor_delivery'))
        OR (v_assignment.station_type = 'tray'
          AND request.status IN ('awaiting_tray_to_kitchen', 'awaiting_tray_return'))
        OR (v_assignment.station_type = 'kitchen'
          AND request.status = 'awaiting_kitchen_packaging')
      );
  END IF;

  RETURN jsonb_set(
    COALESCE(v_payload, '{}'::jsonb),
    '{leftover_packaging_tasks}', v_tasks, true
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_emergency_station_today_completed()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
BEGIN
  RETURN public.emergency_add_takeout_flags(
    public.get_emergency_station_today_completed_pre_takeout()
  );
END;
$$;

-- Keep QR active-order reads small by composing the existing authoritative
-- response with immutable takeout flags in its own current implementation.
ALTER FUNCTION public.qr_get_active_order(text)
  RENAME TO qr_get_active_order_pre_takeout;

CREATE OR REPLACE FUNCTION public.qr_get_active_order(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
DECLARE
  v_payload jsonb;
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_order public.orders%ROWTYPE;
  v_items jsonb;
BEGIN
  v_payload := public.qr_get_active_order_pre_takeout(p_token);
  IF COALESCE((v_payload->>'active')::boolean, false) = false THEN
    RETURN v_payload || jsonb_build_object('leftover_packaging_status', NULL);
  END IF;
  SELECT q.restaurant_id, q.table_id INTO v_table
  FROM public.table_qr_tokens q
  WHERE q.token = v_token AND q.is_active = true;
  SELECT * INTO v_order FROM public.orders
  WHERE restaurant_id = v_table.restaurant_id
    AND table_id = v_table.table_id
    AND status IN ('pending', 'confirmed', 'serving')
  ORDER BY created_at DESC LIMIT 1;

  SELECT COALESCE(jsonb_agg(
    source_item.raw || jsonb_build_object(
      'is_takeout', COALESCE(order_item.is_takeout, false)
    ) ORDER BY source_item.ord
  ), '[]'::jsonb)
  INTO v_items
  FROM jsonb_array_elements(COALESCE(v_payload->'items', '[]'::jsonb))
    WITH ORDINALITY source_item(raw, ord)
  LEFT JOIN LATERAL (
    SELECT oi.is_takeout
    FROM public.order_items oi
    WHERE oi.order_id = v_order.id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
      AND COALESCE(oi.is_service_item, false) = false
    ORDER BY oi.created_at, oi.id
    OFFSET (source_item.ord - 1) LIMIT 1
  ) order_item ON true;

  RETURN jsonb_set(v_payload, '{items}', v_items, true)
    || jsonb_build_object(
      'leftover_packaging_status', (
        SELECT request.status FROM public.leftover_packaging_requests request
        WHERE request.order_id = v_order.id
      )
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_leftover_packaging_on_order_cancel()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_catalog
AS $$
BEGIN
  IF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM NEW.status THEN
    UPDATE public.leftover_packaging_requests
    SET status = 'cancelled', updated_at = now()
    WHERE order_id = NEW.id
      AND status NOT IN ('completed', 'cancelled');
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS cancel_leftover_packaging_on_order_cancel_trigger
  ON public.orders;
CREATE TRIGGER cancel_leftover_packaging_on_order_cancel_trigger
AFTER UPDATE OF status ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.cancel_leftover_packaging_on_order_cancel();

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = 'leftover_packaging_requests'
     ) THEN
    ALTER PUBLICATION supabase_realtime
      ADD TABLE public.leftover_packaging_requests;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.create_leftover_packaging_request_core(
  uuid, uuid, uuid, text, uuid
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.request_leftover_packaging(uuid, uuid, uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.qr_request_leftover_packaging(text, uuid)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.emergency_advance_leftover_packaging(uuid, uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.qr_get_leftover_packaging_status(text)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot()
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed()
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.qr_get_active_order(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot_pre_takeout_packaging()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed_pre_takeout()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.qr_get_active_order_pre_takeout(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_leftover_packaging(uuid, uuid, uuid),
  public.emergency_advance_leftover_packaging(uuid, uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.qr_request_leftover_packaging(text, uuid),
  public.qr_get_leftover_packaging_status(text),
  public.qr_get_active_order(text)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_snapshot(),
  public.get_emergency_station_today_completed()
  TO authenticated;

DO $$
DECLARE
  v_snapshot_definition text;
  v_transition_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'order_items'
      AND column_name = 'is_takeout'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name = 'leftover_packaging_requests'
  ) THEN
    RAISE EXCEPTION 'TAKEOUT_LEFTOVER_SCHEMA_VERIFICATION_FAILED';
  END IF;

  SELECT pg_get_functiondef(
    'public.get_emergency_station_snapshot()'::regprocedure
  ) INTO v_snapshot_definition;
  IF v_snapshot_definition NOT LIKE '%leftover_packaging_tasks%'
     OR v_snapshot_definition NOT LIKE '%emergency_add_takeout_flags%' THEN
    RAISE EXCEPTION 'TAKEOUT_LEFTOVER_SNAPSHOT_VERIFICATION_FAILED';
  END IF;

  SELECT pg_get_functiondef(
    'public.emergency_advance_leftover_packaging(uuid,uuid)'::regprocedure
  ) INTO v_transition_definition;
  IF v_transition_definition NOT LIKE '%awaiting_floor_pickup%'
     OR v_transition_definition NOT LIKE '%awaiting_tray_to_kitchen%'
     OR v_transition_definition NOT LIKE '%awaiting_kitchen_packaging%'
     OR v_transition_definition NOT LIKE '%awaiting_tray_return%'
     OR v_transition_definition NOT LIKE '%awaiting_floor_delivery%' THEN
    RAISE EXCEPTION 'LEFTOVER_ROUND_TRIP_VERIFICATION_FAILED';
  END IF;

  IF pg_catalog.has_function_privilege(
       'anon', 'public.request_leftover_packaging(uuid,uuid,uuid)', 'EXECUTE'
     ) OR NOT pg_catalog.has_function_privilege(
       'anon', 'public.qr_request_leftover_packaging(text,uuid)', 'EXECUTE'
     ) OR NOT pg_catalog.has_function_privilege(
       'authenticated',
       'public.emergency_advance_leftover_packaging(uuid,uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'TAKEOUT_LEFTOVER_GRANT_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
