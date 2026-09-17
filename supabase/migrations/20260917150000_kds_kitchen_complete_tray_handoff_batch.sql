BEGIN;

-- production-gate: self-verifying

-- A kitchen completion makes one unit immediately actionable at the tray.
-- The sequence is durable so reconnects preserve completion order.
CREATE TABLE public.emergency_tray_ready_sequences (
  restaurant_id uuid PRIMARY KEY
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  current_sequence bigint NOT NULL DEFAULT 0 CHECK (current_sequence >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.emergency_tray_ready_lots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  session_id uuid NOT NULL
    REFERENCES public.emergency_fulfillment_sessions(id) ON DELETE CASCADE,
  queue_id uuid NOT NULL REFERENCES public.emergency_order_queue(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid NOT NULL REFERENCES public.order_items(id) ON DELETE CASCADE,
  source_kind text NOT NULL CHECK (source_kind IN ('base', 'combo_component')),
  source_id uuid NOT NULL,
  kitchen_event_id uuid NOT NULL,
  ready_sequence bigint NOT NULL CHECK (ready_sequence > 0),
  ready_quantity integer NOT NULL CHECK (ready_quantity > 0),
  handed_quantity integer NOT NULL DEFAULT 0 CHECK (handed_quantity >= 0),
  voided_quantity integer NOT NULL DEFAULT 0 CHECK (voided_quantity >= 0),
  ready_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT emergency_tray_ready_lot_balance CHECK (
    handed_quantity + voided_quantity <= ready_quantity
  ),
  UNIQUE (kitchen_event_id, source_kind, source_id)
);

CREATE INDEX emergency_tray_ready_lots_queue_pending
  ON public.emergency_tray_ready_lots
  (restaurant_id, queue_id, ready_sequence, id)
  WHERE handed_quantity + voided_quantity < ready_quantity;
CREATE INDEX emergency_tray_ready_lots_line_pending
  ON public.emergency_tray_ready_lots
  (source_kind, source_id, ready_sequence, id)
  WHERE handed_quantity + voided_quantity < ready_quantity;

ALTER TABLE public.emergency_tray_ready_sequences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emergency_tray_ready_lots ENABLE ROW LEVEL SECURITY;
CREATE POLICY emergency_tray_ready_lots_store_read
ON public.emergency_tray_ready_lots
FOR SELECT TO authenticated
USING (public.is_super_admin() OR EXISTS (
  SELECT 1 FROM public.user_accessible_stores((SELECT auth.uid())) scope(store_id)
  WHERE scope.store_id = restaurant_id
));
REVOKE ALL ON public.emergency_tray_ready_sequences
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.emergency_tray_ready_lots
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.emergency_tray_ready_lots TO authenticated;
GRANT ALL ON public.emergency_tray_ready_sequences TO service_role;
GRANT ALL ON public.emergency_tray_ready_lots TO service_role;

CREATE OR REPLACE FUNCTION public.emergency_next_tray_ready_sequence(
  p_restaurant_id uuid
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_sequence bigint;
BEGIN
  INSERT INTO public.emergency_tray_ready_sequences (
    restaurant_id, current_sequence
  ) VALUES (p_restaurant_id, 1)
  ON CONFLICT (restaurant_id) DO UPDATE
  SET current_sequence = emergency_tray_ready_sequences.current_sequence + 1,
      updated_at = now()
  RETURNING current_sequence INTO v_sequence;
  RETURN v_sequence;
END;
$$;
REVOKE ALL ON FUNCTION public.emergency_next_tray_ready_sequence(uuid)
  FROM PUBLIC, anon, authenticated;

-- Legacy delivery rows still use kitchen_done directly. Keep the compatibility
-- shadow column synchronized so the workflow-v2 quantity constraint cannot
-- break that established path.
CREATE OR REPLACE FUNCTION public.emergency_preserve_started_quantity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  NEW.kitchen_started_quantity := GREATEST(
    NEW.kitchen_started_quantity, NEW.kitchen_done_quantity
  );
  NEW.ordered_quantity := GREATEST(
    NEW.ordered_quantity, NEW.kitchen_started_quantity + NEW.excused_quantity
  );
  IF NEW.source_quantity < NEW.kitchen_started_quantity THEN
    NEW.needs_review := true;
  END IF;
  RETURN NEW;
END;
$$;

-- Under the previous v2 meaning, kitchen_started was only an acknowledgement.
-- Reset uncompleted acknowledgements instead of falsely presenting them as
-- cooked food after the semantic cut-over.
UPDATE public.emergency_fulfillment_items item
SET kitchen_started_quantity = item.kitchen_done_quantity,
    updated_at = now()
FROM public.emergency_order_queue queue
WHERE queue.id = item.queue_id AND queue.workflow_version = 2
  AND item.kitchen_started_quantity <> item.kitchen_done_quantity;
UPDATE public.emergency_combo_component_items component
SET kitchen_started_quantity = component.kitchen_done_quantity,
    updated_at = now()
FROM public.emergency_order_queue queue
WHERE queue.id = component.queue_id AND queue.workflow_version = 2
  AND component.kitchen_started_quantity <> component.kitchen_done_quantity;

-- Keep the public v3 name for client compatibility, but align the actions with
-- the operator-facing workflow: kitchen_done -> tray_dispatched -> floor_served.
CREATE OR REPLACE FUNCTION public.kds_record_station_progress_v3(
  p_item_id uuid,
  p_source_kind text,
  p_action text,
  p_delta integer,
  p_event_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_item record;
  v_parent public.emergency_fulfillment_items%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_existing public.emergency_fulfillment_events%ROWTYPE;
  v_tray_lot public.emergency_tray_ready_lots%ROWTYPE;
  v_floor_lot public.emergency_floor_ready_lots%ROWTYPE;
  v_started integer;
  v_done integer;
  v_received integer;
  v_dispatched integer;
  v_served integer;
  v_required integer;
  v_parent_value integer;
  v_tray_sequence bigint;
  v_floor_sequence bigint;
  v_response jsonb;
  v_action text;
BEGIN
  IF p_item_id IS NULL OR p_event_id IS NULL OR p_delta NOT IN (-1, 1)
     OR p_source_kind NOT IN ('base', 'combo_component', 'floor_direct')
     OR p_action NOT IN (
       'kitchen_started', 'kitchen_done', 'tray_ready',
       'tray_dispatched', 'floor_served'
     ) THEN
    RAISE EXCEPTION 'KDS_WORKFLOW_INPUT_INVALID';
  END IF;
  v_action := CASE p_action
    WHEN 'kitchen_started' THEN 'kitchen_done'
    WHEN 'tray_ready' THEN 'tray_dispatched'
    ELSE p_action
  END;

  IF p_source_kind = 'floor_direct' THEN
    IF v_action <> 'floor_served' THEN
      RAISE EXCEPTION 'KDS_WORKFLOW_ROUTE_INVALID';
    END IF;
    RETURN public.emergency_record_floor_direct_progress(
      p_item_id, p_delta, p_event_id
    );
  END IF;

  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_STATION_REQUIRED'; END IF;

  IF p_source_kind = 'combo_component' THEN
    SELECT * INTO v_item FROM public.emergency_combo_component_items
    WHERE id = p_item_id FOR UPDATE;
  ELSE
    SELECT * INTO v_item FROM public.emergency_fulfillment_items
    WHERE id = p_item_id FOR UPDATE;
  END IF;
  IF v_item.id IS NULL OR v_item.restaurant_id <> v_assignment.restaurant_id
     OR v_item.is_cancelled OR v_item.needs_review THEN
    RAISE EXCEPTION 'EMERGENCY_ITEM_UNAVAILABLE';
  END IF;
  SELECT * INTO v_queue FROM public.emergency_order_queue
  WHERE id = v_item.queue_id FOR UPDATE;
  IF v_queue.workflow_version <> 2 OR EXISTS (
    SELECT 1 FROM public.orders order_row
    WHERE order_row.id = v_queue.order_id
      AND COALESCE(order_row.sales_channel, 'dine_in') = 'delivery'
  ) THEN RAISE EXCEPTION 'KDS_WORKFLOW_VERSION_UNAVAILABLE'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_sessions
    WHERE id = v_item.session_id AND status = 'active'
  ) THEN RAISE EXCEPTION 'EMERGENCY_SESSION_NOT_ACTIVE'; END IF;

  SELECT * INTO v_existing FROM public.emergency_fulfillment_events
  WHERE event_id = p_event_id;
  IF FOUND THEN
    IF v_existing.details->>'workflow_action' <> p_action
       OR v_existing.details->>'source_kind' <> p_source_kind
       OR v_existing.details->>'source_id' <> p_item_id::text
       OR v_existing.delta <> p_delta THEN
      RAISE EXCEPTION 'KDS_EVENT_ID_CONFLICT';
    END IF;
    RETURN COALESCE(v_existing.details->'response', '{}'::jsonb)
      || jsonb_build_object('event_id', p_event_id, 'deduplicated', true);
  END IF;

  IF (v_action = 'kitchen_done' AND v_assignment.station_type <> 'kitchen')
     OR (v_action = 'tray_dispatched' AND v_assignment.station_type <> 'tray')
     OR (v_action = 'floor_served' AND (
       v_assignment.station_type <> 'floor'
       OR v_assignment.floor_label <> v_queue.floor_label)) THEN
    RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN';
  END IF;

  v_started := v_item.kitchen_started_quantity
    + CASE WHEN v_action = 'kitchen_done' THEN p_delta ELSE 0 END;
  v_done := v_item.kitchen_done_quantity
    + CASE WHEN v_action = 'kitchen_done' THEN p_delta ELSE 0 END;
  v_received := v_item.tray_received_quantity
    + CASE WHEN v_action = 'tray_dispatched' THEN p_delta ELSE 0 END;
  v_dispatched := v_item.tray_dispatched_quantity
    + CASE WHEN v_action = 'tray_dispatched' THEN p_delta ELSE 0 END;
  v_served := v_item.floor_served_quantity
    + CASE WHEN v_action = 'floor_served' THEN p_delta ELSE 0 END;
  v_required := v_item.ordered_quantity - v_item.excused_quantity;
  IF v_served < 0 OR v_served > v_dispatched
     OR v_dispatched <> v_received OR v_dispatched > v_done
     OR v_done <> v_started OR v_done < 0 OR v_done > v_required THEN
    RAISE EXCEPTION 'EMERGENCY_QUANTITY_CHAIN_VIOLATION';
  END IF;

  IF v_action = 'kitchen_done' AND p_delta > 0 THEN
    v_tray_sequence := public.emergency_next_tray_ready_sequence(
      v_item.restaurant_id
    );
    INSERT INTO public.emergency_tray_ready_lots (
      restaurant_id, session_id, queue_id, order_id, order_item_id,
      source_kind, source_id, kitchen_event_id, ready_sequence, ready_quantity
    ) VALUES (
      v_item.restaurant_id, v_item.session_id, v_item.queue_id,
      v_item.order_id, v_item.order_item_id, p_source_kind, v_item.id,
      p_event_id, v_tray_sequence, 1
    );
  ELSIF v_action = 'kitchen_done' AND p_delta < 0 THEN
    SELECT * INTO v_tray_lot FROM public.emergency_tray_ready_lots lot
    WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
      AND lot.handed_quantity + lot.voided_quantity < lot.ready_quantity
    ORDER BY lot.ready_sequence DESC, lot.id DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KDS_TRAY_READY_LOT_MISSING'; END IF;
    UPDATE public.emergency_tray_ready_lots
    SET voided_quantity = voided_quantity + 1, updated_at = now()
    WHERE id = v_tray_lot.id;
  ELSIF v_action = 'tray_dispatched' AND p_delta > 0 THEN
    SELECT * INTO v_tray_lot FROM public.emergency_tray_ready_lots lot
    WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
      AND lot.handed_quantity + lot.voided_quantity < lot.ready_quantity
    ORDER BY lot.ready_sequence, lot.id LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KDS_TRAY_READY_LOT_MISSING'; END IF;
    UPDATE public.emergency_tray_ready_lots
    SET handed_quantity = handed_quantity + 1, updated_at = now()
    WHERE id = v_tray_lot.id;
    v_floor_sequence := public.emergency_next_floor_ready_sequence(
      v_item.restaurant_id
    );
    INSERT INTO public.emergency_floor_ready_lots (
      restaurant_id, session_id, queue_id, order_id, order_item_id,
      source_kind, source_id, ready_action_id, ready_sequence, ready_quantity
    ) VALUES (
      v_item.restaurant_id, v_item.session_id, v_item.queue_id,
      v_item.order_id, v_item.order_item_id, p_source_kind, v_item.id,
      p_event_id, v_floor_sequence, 1
    );
  ELSIF v_action = 'tray_dispatched' AND p_delta < 0 THEN
    SELECT * INTO v_floor_lot FROM public.emergency_floor_ready_lots lot
    WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
      AND lot.served_quantity = 0
      AND lot.voided_quantity < lot.ready_quantity
    ORDER BY lot.ready_sequence DESC, lot.id DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KDS_READY_LOT_MISSING'; END IF;
    UPDATE public.emergency_floor_ready_lots
    SET voided_quantity = voided_quantity + 1, updated_at = now()
    WHERE id = v_floor_lot.id;
    SELECT * INTO v_tray_lot FROM public.emergency_tray_ready_lots lot
    WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
      AND lot.handed_quantity > 0
    ORDER BY lot.ready_sequence DESC, lot.id DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KDS_TRAY_READY_LOT_MISSING'; END IF;
    UPDATE public.emergency_tray_ready_lots
    SET handed_quantity = handed_quantity - 1, updated_at = now()
    WHERE id = v_tray_lot.id;
  ELSIF v_action = 'floor_served' AND p_delta > 0 THEN
    SELECT * INTO v_floor_lot FROM public.emergency_floor_ready_lots lot
    WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
      AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity
    ORDER BY lot.ready_sequence, lot.id LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KDS_READY_LOT_MISSING'; END IF;
    UPDATE public.emergency_floor_ready_lots
    SET served_quantity = served_quantity + 1, updated_at = now()
    WHERE id = v_floor_lot.id;
  ELSIF v_action = 'floor_served' AND p_delta < 0 THEN
    SELECT * INTO v_floor_lot FROM public.emergency_floor_ready_lots lot
    WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
      AND lot.served_quantity > 0
    ORDER BY lot.ready_sequence DESC, lot.id DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KDS_SERVED_LOT_MISSING'; END IF;
    UPDATE public.emergency_floor_ready_lots
    SET served_quantity = served_quantity - 1, updated_at = now()
    WHERE id = v_floor_lot.id;
  END IF;

  IF p_source_kind = 'combo_component' THEN
    UPDATE public.emergency_combo_component_items
    SET kitchen_started_quantity = v_started,
        kitchen_done_quantity = v_done,
        tray_received_quantity = v_received,
        tray_dispatched_quantity = v_dispatched,
        floor_served_quantity = v_served,
        updated_at = now()
    WHERE id = v_item.id;
    SELECT * INTO v_parent FROM public.emergency_fulfillment_items
    WHERE session_id = v_item.session_id
      AND order_item_id = v_item.order_item_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_PARENT_ITEM_UNAVAILABLE'; END IF;
    SELECT COALESCE(min(
      CASE v_action
        WHEN 'kitchen_done' THEN component.kitchen_done_quantity
        WHEN 'tray_dispatched' THEN component.tray_dispatched_quantity
        ELSE component.floor_served_quantity
      END * v_parent.ordered_quantity / component.ordered_quantity
    ), 0)::integer INTO v_parent_value
    FROM public.emergency_combo_component_items component
    WHERE component.session_id = v_item.session_id
      AND component.order_item_id = v_item.order_item_id
      AND component.is_cancelled = false;
    UPDATE public.emergency_fulfillment_items SET
      kitchen_started_quantity = CASE WHEN v_action = 'kitchen_done'
        THEN v_parent_value ELSE kitchen_started_quantity END,
      kitchen_done_quantity = CASE WHEN v_action = 'kitchen_done'
        THEN v_parent_value ELSE kitchen_done_quantity END,
      tray_received_quantity = CASE WHEN v_action = 'tray_dispatched'
        THEN v_parent_value ELSE tray_received_quantity END,
      tray_dispatched_quantity = CASE WHEN v_action = 'tray_dispatched'
        THEN v_parent_value ELSE tray_dispatched_quantity END,
      floor_served_quantity = CASE WHEN v_action = 'floor_served'
        THEN v_parent_value ELSE floor_served_quantity END,
      updated_at = now()
    WHERE id = v_parent.id;
  ELSE
    UPDATE public.emergency_fulfillment_items
    SET kitchen_started_quantity = v_started,
        kitchen_done_quantity = v_done,
        tray_received_quantity = v_received,
        tray_dispatched_quantity = v_dispatched,
        floor_served_quantity = v_served,
        updated_at = now()
    WHERE id = v_item.id;
  END IF;

  SELECT min(lot.ready_sequence) INTO v_tray_sequence
  FROM public.emergency_tray_ready_lots lot
  WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
    AND lot.handed_quantity + lot.voided_quantity < lot.ready_quantity;
  SELECT min(lot.ready_sequence) INTO v_floor_sequence
  FROM public.emergency_floor_ready_lots lot
  WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
    AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity;
  v_response := jsonb_build_object(
    'kitchen_started_quantity', v_started,
    'kitchen_done_quantity', v_done,
    'tray_received_quantity', v_received,
    'tray_dispatched_quantity', v_dispatched,
    'floor_served_quantity', v_served,
    'oldest_tray_ready_sequence', v_tray_sequence,
    'oldest_ready_sequence', v_floor_sequence
  );
  INSERT INTO public.emergency_fulfillment_events (
    event_id, session_id, restaurant_id, order_id, order_item_id,
    combo_component_item_id, stage, delta, actor_user_id, details
  ) VALUES (
    p_event_id, v_item.session_id, v_item.restaurant_id, v_item.order_id,
    v_item.order_item_id,
    CASE WHEN p_source_kind = 'combo_component' THEN v_item.id END,
    v_action, p_delta, v_user.id,
    jsonb_build_object(
      'workflow_action', p_action, 'source_kind', p_source_kind,
      'effective_action', v_action, 'source_id', v_item.id,
      'response', v_response
    )
  );
  IF p_delta > 0 AND v_action IN ('kitchen_done', 'tray_dispatched') THEN
    PERFORM public.emergency_enqueue_push(
      p_event_id, v_item.restaurant_id, v_item.order_id,
      CASE v_action WHEN 'kitchen_done' THEN 'tray' ELSE 'floor' END,
      v_queue.floor_label, v_action
    );
  END IF;
  RETURN v_response || jsonb_build_object(
    'event_id', p_event_id, 'deduplicated', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.kds_record_station_progress_v3(
  uuid, text, text, integer, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kds_record_station_progress_v3(
  uuid, text, text, integer, uuid
) TO authenticated;

CREATE TABLE public.emergency_kitchen_batch_actions (
  request_id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  allocation_hash text NOT NULL,
  response jsonb NOT NULL,
  created_by uuid NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.emergency_kitchen_batch_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.emergency_kitchen_batch_actions
  FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.emergency_kitchen_batch_actions TO service_role;

-- All allocations run in one database statement. Any stale quantity or invalid
-- line rolls the entire batch back, so the UI cannot partially complete a list.
CREATE OR REPLACE FUNCTION public.kds_complete_kitchen_batch_v1(
  p_request_id uuid,
  p_allocations jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_existing public.emergency_kitchen_batch_actions%ROWTYPE;
  v_allocation jsonb;
  v_item_id uuid;
  v_source_kind text;
  v_quantity integer;
  v_workflow smallint;
  v_queue_id uuid;
  v_first_queue_id uuid;
  v_name_ko text;
  v_name_vi text;
  v_name_en text;
  v_pending integer;
  v_count integer;
  v_changed integer := 0;
  v_hash text;
  v_response jsonb;
BEGIN
  IF p_request_id IS NULL OR jsonb_typeof(p_allocations) <> 'array'
     OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'KDS_CHECKET_BATCH_INPUT_INVALID';
  END IF;
  v_hash := md5(p_allocations::text);
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment FROM public.emergency_station_assignments
  WHERE user_id = v_user.id AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND OR v_assignment.station_type <> 'kitchen' THEN
    RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN';
  END IF;
  SELECT * INTO v_existing FROM public.emergency_kitchen_batch_actions
  WHERE request_id = p_request_id;
  IF FOUND THEN
    IF v_existing.restaurant_id <> v_assignment.restaurant_id
       OR v_existing.allocation_hash <> v_hash THEN
      RAISE EXCEPTION 'KDS_EVENT_ID_CONFLICT';
    END IF;
    RETURN v_existing.response || jsonb_build_object('deduplicated', true);
  END IF;
  SELECT count(*)::integer, COALESCE(sum(quantity), 0)::integer
  INTO v_count, v_changed
  FROM (
    SELECT NULLIF(value->>'item_id', '')::uuid AS item_id,
      value->>'source_kind' AS source_kind,
      (value->>'quantity')::integer AS quantity
    FROM jsonb_array_elements(p_allocations)
  ) parsed;
  IF v_count > 1000 OR v_changed > 1000 OR EXISTS (
    SELECT 1 FROM (
      SELECT NULLIF(value->>'item_id', '')::uuid AS item_id,
        value->>'source_kind' AS source_kind,
        (value->>'quantity')::integer AS quantity
      FROM jsonb_array_elements(p_allocations)
    ) parsed
    WHERE item_id IS NULL OR source_kind NOT IN ('base', 'combo_component')
      OR quantity <= 0
  ) OR EXISTS (
    SELECT 1 FROM (
      SELECT NULLIF(value->>'item_id', '')::uuid AS item_id,
        value->>'source_kind' AS source_kind
      FROM jsonb_array_elements(p_allocations)
    ) parsed GROUP BY item_id, source_kind HAVING count(*) > 1
  ) THEN RAISE EXCEPTION 'KDS_CHECKET_BATCH_INPUT_INVALID'; END IF;

  FOR v_allocation IN SELECT value FROM jsonb_array_elements(p_allocations)
  LOOP
    v_item_id := NULLIF(v_allocation->>'item_id', '')::uuid;
    v_source_kind := v_allocation->>'source_kind';
    v_quantity := (v_allocation->>'quantity')::integer;
    IF v_source_kind = 'combo_component' THEN
      SELECT queue.workflow_version, queue.id,
        item.name_ko, item.name_vi, item.name_en,
        item.ordered_quantity - item.excused_quantity
          - item.kitchen_done_quantity
      INTO v_workflow, v_queue_id, v_name_ko, v_name_vi, v_name_en, v_pending
      FROM public.emergency_combo_component_items item
      JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
      WHERE item.id = v_item_id AND item.restaurant_id = v_assignment.restaurant_id
        AND item.is_cancelled = false AND item.needs_review = false;
    ELSE
      SELECT queue.workflow_version, queue.id,
        COALESCE(NULLIF(order_item.label, ''),
          NULLIF(order_item.display_name, ''), menu.name_ko, menu.name, '메뉴'),
        COALESCE(NULLIF(menu.paperless_name_vi, ''),
          NULLIF(menu.name_vi, ''), NULLIF(order_item.display_name, ''),
          menu.name, 'Món'),
        COALESCE(NULLIF(menu.name_en, ''),
          NULLIF(order_item.display_name, ''), menu.name, 'Item'),
        item.ordered_quantity - item.excused_quantity
          - item.kitchen_done_quantity
      INTO v_workflow, v_queue_id, v_name_ko, v_name_vi, v_name_en, v_pending
      FROM public.emergency_fulfillment_items item
      JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
      JOIN public.order_items order_item ON order_item.id = item.order_item_id
      LEFT JOIN public.menu_items menu ON menu.id = order_item.menu_item_id
      WHERE item.id = v_item_id AND item.restaurant_id = v_assignment.restaurant_id
        AND item.is_cancelled = false AND item.needs_review = false;
    END IF;
    IF v_workflow IS NULL OR v_pending < v_quantity THEN
      RAISE EXCEPTION 'KDS_CHECKET_SELECTION_STALE';
    END IF;

    -- Recalculate the earliest pending order for this displayed menu inside
    -- the transaction. This prevents a stale or modified client from skipping
    -- an older order while still allowing duplicate lines within one order.
    SELECT candidate.queue_id INTO v_first_queue_id
    FROM (
      SELECT queue.id AS queue_id, queue.created_at, queue.queue_no
      FROM public.emergency_fulfillment_items item
      JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
      JOIN public.emergency_fulfillment_sessions session
        ON session.id = item.session_id AND session.status = 'active'
      JOIN public.order_items order_item ON order_item.id = item.order_item_id
      LEFT JOIN public.menu_items menu ON menu.id = order_item.menu_item_id
      WHERE item.restaurant_id = v_assignment.restaurant_id
        AND item.is_cancelled = false AND item.needs_review = false
        AND item.kitchen_done_quantity
          < item.ordered_quantity - item.excused_quantity
        AND NOT EXISTS (
          SELECT 1 FROM public.emergency_combo_component_items component
          WHERE component.session_id = item.session_id
            AND component.order_item_id = item.order_item_id
            AND component.is_cancelled = false
        )
        AND lower(btrim(COALESCE(NULLIF(order_item.label, ''),
          NULLIF(order_item.display_name, ''), menu.name_ko, menu.name, '메뉴')))
          = lower(btrim(v_name_ko))
        AND lower(btrim(COALESCE(NULLIF(menu.paperless_name_vi, ''),
          NULLIF(menu.name_vi, ''), NULLIF(order_item.display_name, ''),
          menu.name, 'Món'))) = lower(btrim(v_name_vi))
        AND lower(btrim(COALESCE(NULLIF(menu.name_en, ''),
          NULLIF(order_item.display_name, ''), menu.name, 'Item')))
          = lower(btrim(v_name_en))
      UNION ALL
      SELECT queue.id, queue.created_at, queue.queue_no
      FROM public.emergency_combo_component_items item
      JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
      JOIN public.emergency_fulfillment_sessions session
        ON session.id = item.session_id AND session.status = 'active'
      WHERE item.restaurant_id = v_assignment.restaurant_id
        AND item.is_cancelled = false AND item.needs_review = false
        AND item.kitchen_done_quantity
          < item.ordered_quantity - item.excused_quantity
        AND lower(btrim(item.name_ko)) = lower(btrim(v_name_ko))
        AND lower(btrim(item.name_vi)) = lower(btrim(v_name_vi))
        AND lower(btrim(item.name_en)) = lower(btrim(v_name_en))
    ) candidate
    ORDER BY candidate.created_at, candidate.queue_no, candidate.queue_id
    LIMIT 1;
    IF v_first_queue_id IS DISTINCT FROM v_queue_id THEN
      RAISE EXCEPTION 'KDS_CHECKET_SELECTION_STALE';
    END IF;
    FOR v_index IN 1..v_quantity LOOP
      IF v_workflow = 2 THEN
        PERFORM public.kds_record_station_progress_v3(
          v_item_id, v_source_kind, 'kitchen_done', 1, gen_random_uuid()
        );
      ELSE
        PERFORM public.kds_record_progress_v2(
          v_item_id, 'kitchen_done', 1, gen_random_uuid(), v_source_kind
        );
      END IF;
    END LOOP;
  END LOOP;
  v_response := jsonb_build_object(
    'request_id', p_request_id,
    'changed_quantity', v_changed,
    'deduplicated', false
  );
  INSERT INTO public.emergency_kitchen_batch_actions (
    request_id, restaurant_id, allocation_hash, response, created_by
  ) VALUES (
    p_request_id, v_assignment.restaurant_id, v_hash, v_response, v_user.id
  );
  RETURN v_response;
END;
$$;
REVOKE ALL ON FUNCTION public.kds_complete_kitchen_batch_v1(uuid, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kds_complete_kitchen_batch_v1(uuid, jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.kds_set_workflow_event_targets()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_delivery boolean := false; v_targets text[];
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.kds_realtime_rollouts rollout
    WHERE rollout.restaurant_id = NEW.restaurant_id
      AND rollout.mode IN ('shadow', 'active')
  ) THEN RETURN NEW; END IF;
  SELECT COALESCE(order_row.sales_channel, 'dine_in') = 'delivery'
  INTO v_delivery FROM public.orders order_row WHERE order_row.id = NEW.order_id;
  v_targets := CASE NEW.stage
    WHEN 'kitchen_started' THEN ARRAY['kitchen', 'tray']::text[]
    WHEN 'kitchen_done' THEN ARRAY['kitchen', 'tray']::text[]
    WHEN 'tray_ready' THEN CASE WHEN v_delivery
      THEN ARRAY['tray']::text[]
      ELSE ARRAY['kitchen', 'tray', 'floor']::text[] END
    WHEN 'tray_received' THEN ARRAY['tray']::text[]
    WHEN 'tray_dispatched' THEN CASE WHEN v_delivery
      THEN ARRAY['tray']::text[] ELSE ARRAY['tray', 'floor']::text[] END
    WHEN 'floor_served' THEN ARRAY['floor']::text[]
    WHEN 'fulfillment_cancelled' THEN ARRAY['kitchen', 'tray', 'floor']::text[]
    WHEN 'order_received' THEN CASE WHEN v_delivery
      THEN ARRAY['kitchen', 'tray']::text[]
      ELSE ARRAY['kitchen', 'tray', 'floor']::text[] END
    ELSE NULL
  END;
  IF v_targets IS NOT NULL THEN
    UPDATE public.kds_change_log change
    SET target_stations = v_targets,
        target_floor_label = CASE WHEN 'floor' = ANY(v_targets)
          THEN queue.floor_label ELSE change.target_floor_label END
    FROM public.emergency_order_queue queue
    WHERE change.event_id = NEW.event_id
      AND queue.session_id = NEW.session_id
      AND queue.order_id = NEW.order_id;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.kds_set_workflow_event_targets()
  FROM PUBLIC, anon, authenticated;

-- Existing snapshot wrappers already call this helper, so replacing it adds the
-- tray sequence to snapshots, completed lists and realtime ticket catch-up.
CREATE OR REPLACE FUNCTION public.emergency_enrich_start_ready_orders(
  p_orders jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_result jsonb := '[]'::jsonb;
  v_order jsonb;
  v_item jsonb;
  v_items jsonb;
  v_workflow smallint;
  v_started integer;
  v_excused integer;
  v_floor_sequence bigint;
  v_tray_sequence bigint;
BEGIN
  IF COALESCE(jsonb_typeof(p_orders), 'null') <> 'array' THEN
    RETURN '[]'::jsonb;
  END IF;
  FOR v_order IN SELECT value FROM jsonb_array_elements(p_orders)
  LOOP
    SELECT queue.workflow_version INTO v_workflow
    FROM public.emergency_order_queue queue
    WHERE queue.id = NULLIF(v_order->>'queue_id', '')::uuid;
    v_workflow := COALESCE(v_workflow, 1);
    v_items := '[]'::jsonb;
    FOR v_item IN
      SELECT value FROM jsonb_array_elements(COALESCE(v_order->'items', '[]'))
    LOOP
      v_started := NULL; v_excused := 0;
      v_floor_sequence := NULL; v_tray_sequence := NULL;
      IF v_item->>'source_kind' = 'combo_component' THEN
        SELECT component.kitchen_started_quantity, component.excused_quantity
        INTO v_started, v_excused
        FROM public.emergency_combo_component_items component
        WHERE component.id = NULLIF(v_item->>'id', '')::uuid;
        SELECT min(lot.ready_sequence) INTO v_tray_sequence
        FROM public.emergency_tray_ready_lots lot
        WHERE lot.source_kind = 'combo_component'
          AND lot.source_id = NULLIF(v_item->>'id', '')::uuid
          AND lot.handed_quantity + lot.voided_quantity < lot.ready_quantity;
        SELECT min(lot.ready_sequence) INTO v_floor_sequence
        FROM public.emergency_floor_ready_lots lot
        WHERE lot.source_kind = 'combo_component'
          AND lot.source_id = NULLIF(v_item->>'id', '')::uuid
          AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity;
      ELSIF COALESCE(v_item->>'fulfillment_route', '') <> 'floor_direct' THEN
        SELECT item.kitchen_started_quantity, item.excused_quantity
        INTO v_started, v_excused FROM public.emergency_fulfillment_items item
        WHERE item.id = NULLIF(v_item->>'id', '')::uuid;
        SELECT min(lot.ready_sequence) INTO v_tray_sequence
        FROM public.emergency_tray_ready_lots lot
        WHERE lot.source_kind = 'base'
          AND lot.source_id = NULLIF(v_item->>'id', '')::uuid
          AND lot.handed_quantity + lot.voided_quantity < lot.ready_quantity;
        SELECT min(lot.ready_sequence) INTO v_floor_sequence
        FROM public.emergency_floor_ready_lots lot
        WHERE lot.source_kind = 'base'
          AND lot.source_id = NULLIF(v_item->>'id', '')::uuid
          AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity;
      ELSE
        SELECT direct_item.excused_quantity INTO v_excused
        FROM public.emergency_floor_direct_items direct_item
        WHERE direct_item.id = NULLIF(v_item->>'id', '')::uuid;
      END IF;
      v_items := v_items || jsonb_build_array(v_item || jsonb_build_object(
        'workflow_version', v_workflow,
        'kitchen_started_quantity', COALESCE(
          v_started, (v_item->>'kitchen_done_quantity')::integer, 0
        ),
        'excused_quantity', COALESCE(v_excused, 0),
        'required_quantity', GREATEST(
          COALESCE((v_item->>'ordered_quantity')::integer, 0)
            - COALESCE(v_excused, 0), 0
        ),
        'oldest_tray_ready_sequence', v_tray_sequence,
        'oldest_ready_sequence', v_floor_sequence
      ));
    END LOOP;
    SELECT min(lot.ready_sequence) INTO v_tray_sequence
    FROM public.emergency_tray_ready_lots lot
    WHERE lot.queue_id = NULLIF(v_order->>'queue_id', '')::uuid
      AND lot.handed_quantity + lot.voided_quantity < lot.ready_quantity;
    SELECT min(lot.ready_sequence) INTO v_floor_sequence
    FROM public.emergency_floor_ready_lots lot
    WHERE lot.queue_id = NULLIF(v_order->>'queue_id', '')::uuid
      AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity;
    v_result := v_result || jsonb_build_array(
      jsonb_set(v_order, '{items}', v_items, true) || jsonb_build_object(
        'workflow_version', v_workflow,
        'oldest_tray_ready_sequence', v_tray_sequence,
        'oldest_ready_sequence', v_floor_sequence
      )
    );
  END LOOP;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb)
  FROM PUBLIC, anon, authenticated;

DO $$
DECLARE v_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'::regprocedure
  ) INTO v_definition;
  IF v_definition NOT LIKE '%kitchen_done%'
     OR v_definition NOT LIKE '%tray_dispatched%'
     OR v_definition NOT LIKE '%emergency_tray_ready_lots%' THEN
    RAISE EXCEPTION 'KDS_KITCHEN_HANDOFF_FUNCTION_VERIFICATION_FAILED';
  END IF;
  IF NOT pg_catalog.has_function_privilege(
    'authenticated', 'public.kds_complete_kitchen_batch_v1(uuid,jsonb)', 'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon', 'public.kds_complete_kitchen_batch_v1(uuid,jsonb)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'KDS_KITCHEN_BATCH_GRANT_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
