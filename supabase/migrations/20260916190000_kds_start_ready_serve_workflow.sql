BEGIN;

-- production-gate: self-verifying

-- Existing queues retain their historical kitchen-complete semantics. New
-- dine-in queues use the explicit start -> ready -> served workflow.
ALTER TABLE public.emergency_order_queue
  ADD COLUMN IF NOT EXISTS workflow_version smallint;
UPDATE public.emergency_order_queue SET workflow_version = 1
WHERE workflow_version IS NULL;
ALTER TABLE public.emergency_order_queue
  ALTER COLUMN workflow_version SET DEFAULT 2,
  ALTER COLUMN workflow_version SET NOT NULL;
ALTER TABLE public.emergency_order_queue
  DROP CONSTRAINT IF EXISTS emergency_order_queue_workflow_version_check;
ALTER TABLE public.emergency_order_queue
  ADD CONSTRAINT emergency_order_queue_workflow_version_check
  CHECK (workflow_version IN (1, 2));

CREATE OR REPLACE FUNCTION public.emergency_assign_queue_workflow_version()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF NEW.workflow_version IS NULL OR NEW.workflow_version = 2 THEN
    SELECT CASE WHEN COALESCE(order_row.sales_channel, 'dine_in') = 'delivery'
      THEN 1 ELSE 2 END
    INTO NEW.workflow_version
    FROM public.orders order_row
    WHERE order_row.id = NEW.order_id;
    NEW.workflow_version := COALESCE(NEW.workflow_version, 2);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS emergency_assign_queue_workflow_version_trigger
  ON public.emergency_order_queue;
CREATE TRIGGER emergency_assign_queue_workflow_version_trigger
BEFORE INSERT ON public.emergency_order_queue
FOR EACH ROW EXECUTE FUNCTION public.emergency_assign_queue_workflow_version();

ALTER TABLE public.emergency_fulfillment_items
  ADD COLUMN IF NOT EXISTS kitchen_started_quantity integer NOT NULL DEFAULT 0;
ALTER TABLE public.emergency_combo_component_items
  ADD COLUMN IF NOT EXISTS kitchen_started_quantity integer NOT NULL DEFAULT 0;
ALTER TABLE public.emergency_fulfillment_items
  ADD COLUMN IF NOT EXISTS excused_quantity integer NOT NULL DEFAULT 0;
ALTER TABLE public.emergency_combo_component_items
  ADD COLUMN IF NOT EXISTS excused_quantity integer NOT NULL DEFAULT 0;
ALTER TABLE public.emergency_floor_direct_items
  ADD COLUMN IF NOT EXISTS excused_quantity integer NOT NULL DEFAULT 0;

UPDATE public.emergency_fulfillment_items
SET kitchen_started_quantity = kitchen_done_quantity
WHERE kitchen_started_quantity < kitchen_done_quantity;
UPDATE public.emergency_combo_component_items
SET kitchen_started_quantity = kitchen_done_quantity
WHERE kitchen_started_quantity < kitchen_done_quantity;

ALTER TABLE public.emergency_fulfillment_items
  DROP CONSTRAINT IF EXISTS emergency_fulfillment_quantity_chain;
ALTER TABLE public.emergency_fulfillment_items
  ADD CONSTRAINT emergency_fulfillment_quantity_chain CHECK (
    floor_served_quantity >= 0
    AND floor_served_quantity <= tray_dispatched_quantity
    AND tray_dispatched_quantity <= tray_received_quantity
    AND tray_received_quantity <= kitchen_done_quantity
    AND kitchen_done_quantity <= kitchen_started_quantity
    AND excused_quantity >= 0
    AND kitchen_started_quantity + excused_quantity <= ordered_quantity
  );
ALTER TABLE public.emergency_combo_component_items
  DROP CONSTRAINT IF EXISTS emergency_combo_component_quantity_chain;
ALTER TABLE public.emergency_combo_component_items
  ADD CONSTRAINT emergency_combo_component_quantity_chain CHECK (
    floor_served_quantity >= 0
    AND floor_served_quantity <= tray_dispatched_quantity
    AND tray_dispatched_quantity <= tray_received_quantity
    AND tray_received_quantity <= kitchen_done_quantity
    AND kitchen_done_quantity <= kitchen_started_quantity
    AND excused_quantity >= 0
    AND kitchen_started_quantity + excused_quantity <= ordered_quantity
  );
ALTER TABLE public.emergency_floor_direct_items
  DROP CONSTRAINT IF EXISTS emergency_floor_direct_quantity_check;
ALTER TABLE public.emergency_floor_direct_items
  ADD CONSTRAINT emergency_floor_direct_quantity_check CHECK (
    floor_served_quantity >= 0
    AND excused_quantity >= 0
    AND floor_served_quantity + excused_quantity <= ordered_quantity
  );

CREATE OR REPLACE FUNCTION public.emergency_preserve_started_quantity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  NEW.ordered_quantity := GREATEST(
    NEW.ordered_quantity, NEW.kitchen_started_quantity + NEW.excused_quantity
  );
  IF NEW.source_quantity < NEW.kitchen_started_quantity THEN
    NEW.needs_review := true;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS emergency_preserve_started_quantity_trigger
  ON public.emergency_fulfillment_items;
CREATE TRIGGER emergency_preserve_started_quantity_trigger
BEFORE INSERT OR UPDATE OF source_quantity, ordered_quantity,
  kitchen_started_quantity, excused_quantity
ON public.emergency_fulfillment_items
FOR EACH ROW EXECUTE FUNCTION public.emergency_preserve_started_quantity();
DROP TRIGGER IF EXISTS emergency_combo_preserve_started_quantity_trigger
  ON public.emergency_combo_component_items;
CREATE TRIGGER emergency_combo_preserve_started_quantity_trigger
BEFORE INSERT OR UPDATE OF source_quantity, ordered_quantity,
  kitchen_started_quantity, excused_quantity
ON public.emergency_combo_component_items
FOR EACH ROW EXECUTE FUNCTION public.emergency_preserve_started_quantity();

ALTER TABLE public.emergency_fulfillment_events
  DROP CONSTRAINT IF EXISTS emergency_fulfillment_events_stage_check;
ALTER TABLE public.emergency_fulfillment_events
  ADD CONSTRAINT emergency_fulfillment_events_stage_check CHECK (stage IN (
    'order_received', 'kitchen_started', 'kitchen_done', 'tray_ready',
    'tray_received', 'tray_dispatched', 'floor_served',
    'fulfillment_cancelled',
    'floor_direct_ready', 'leftover_requested', 'leftover_floor_to_tray',
    'leftover_tray_to_kitchen', 'leftover_kitchen_packaged',
    'leftover_tray_to_floor', 'leftover_floor_delivered'
  ));

CREATE TABLE public.emergency_floor_ready_sequences (
  restaurant_id uuid PRIMARY KEY
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  current_sequence bigint NOT NULL DEFAULT 0 CHECK (current_sequence >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.emergency_floor_ready_lots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  session_id uuid NOT NULL
    REFERENCES public.emergency_fulfillment_sessions(id) ON DELETE CASCADE,
  queue_id uuid NOT NULL REFERENCES public.emergency_order_queue(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid NOT NULL REFERENCES public.order_items(id) ON DELETE CASCADE,
  source_kind text NOT NULL CHECK (source_kind IN ('base', 'combo_component')),
  source_id uuid NOT NULL,
  ready_action_id uuid NOT NULL,
  ready_sequence bigint NOT NULL CHECK (ready_sequence > 0),
  ready_quantity integer NOT NULL CHECK (ready_quantity > 0),
  served_quantity integer NOT NULL DEFAULT 0 CHECK (served_quantity >= 0),
  voided_quantity integer NOT NULL DEFAULT 0 CHECK (voided_quantity >= 0),
  ready_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT emergency_floor_ready_lot_balance CHECK (
    served_quantity + voided_quantity <= ready_quantity
  ),
  UNIQUE (ready_action_id, source_kind, source_id)
);

CREATE INDEX emergency_floor_ready_lots_queue_pending
  ON public.emergency_floor_ready_lots
  (restaurant_id, queue_id, ready_sequence, id)
  WHERE served_quantity + voided_quantity < ready_quantity;
CREATE INDEX emergency_floor_ready_lots_line_pending
  ON public.emergency_floor_ready_lots
  (source_kind, source_id, ready_sequence, id)
  WHERE served_quantity + voided_quantity < ready_quantity;

ALTER TABLE public.emergency_floor_ready_sequences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.emergency_floor_ready_lots ENABLE ROW LEVEL SECURITY;
CREATE POLICY emergency_floor_ready_lots_store_read
ON public.emergency_floor_ready_lots
FOR SELECT TO authenticated
USING (public.is_super_admin() OR EXISTS (
  SELECT 1 FROM public.user_accessible_stores((SELECT auth.uid())) scope(store_id)
  WHERE scope.store_id = restaurant_id
));
REVOKE ALL ON public.emergency_floor_ready_sequences
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.emergency_floor_ready_lots
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.emergency_floor_ready_lots TO authenticated;
GRANT ALL ON public.emergency_floor_ready_sequences TO service_role;
GRANT ALL ON public.emergency_floor_ready_lots TO service_role;

CREATE OR REPLACE FUNCTION public.emergency_next_floor_ready_sequence(
  p_restaurant_id uuid
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_sequence bigint;
BEGIN
  INSERT INTO public.emergency_floor_ready_sequences (
    restaurant_id, current_sequence
  ) VALUES (p_restaurant_id, 1)
  ON CONFLICT (restaurant_id) DO UPDATE
  SET current_sequence = emergency_floor_ready_sequences.current_sequence + 1,
      updated_at = now()
  RETURNING current_sequence INTO v_sequence;
  RETURN v_sequence;
END;
$$;
REVOKE ALL ON FUNCTION public.emergency_next_floor_ready_sequence(uuid)
  FROM PUBLIC, anon, authenticated;

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
  v_lot public.emergency_floor_ready_lots%ROWTYPE;
  v_started integer;
  v_ready integer;
  v_received integer;
  v_dispatched integer;
  v_served integer;
  v_required integer;
  v_parent_value integer;
  v_sequence bigint;
  v_response jsonb;
BEGIN
  IF p_item_id IS NULL OR p_event_id IS NULL OR p_delta NOT IN (-1, 1)
     OR p_source_kind NOT IN ('base', 'combo_component', 'floor_direct')
     OR p_action NOT IN ('kitchen_started', 'tray_ready', 'floor_served') THEN
    RAISE EXCEPTION 'KDS_WORKFLOW_INPUT_INVALID';
  END IF;

  IF p_source_kind = 'floor_direct' THEN
    IF p_action <> 'floor_served' THEN
      RAISE EXCEPTION 'KDS_WORKFLOW_ROUTE_INVALID';
    END IF;
    SELECT * INTO v_item FROM public.emergency_floor_direct_items
    WHERE id = p_item_id FOR UPDATE;
    IF NOT FOUND OR (
      p_delta > 0 AND
      v_item.floor_served_quantity + v_item.excused_quantity
        >= v_item.ordered_quantity
    ) THEN
      RAISE EXCEPTION 'EMERGENCY_QUANTITY_CHAIN_VIOLATION';
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
    SELECT * INTO v_item
    FROM public.emergency_combo_component_items
    WHERE id = p_item_id FOR UPDATE;
  ELSE
    SELECT * INTO v_item
    FROM public.emergency_fulfillment_items
    WHERE id = p_item_id FOR UPDATE;
  END IF;
  IF v_item.id IS NULL OR v_item.restaurant_id <> v_assignment.restaurant_id
     OR v_item.is_cancelled OR v_item.needs_review THEN
    RAISE EXCEPTION 'EMERGENCY_ITEM_UNAVAILABLE';
  END IF;
  SELECT * INTO v_queue
  FROM public.emergency_order_queue WHERE id = v_item.queue_id FOR UPDATE;
  IF v_queue.workflow_version <> 2 OR EXISTS (
    SELECT 1 FROM public.orders order_row
    WHERE order_row.id = v_queue.order_id
      AND COALESCE(order_row.sales_channel, 'dine_in') = 'delivery'
  ) THEN RAISE EXCEPTION 'KDS_WORKFLOW_VERSION_UNAVAILABLE'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_sessions
    WHERE id = v_item.session_id AND status = 'active'
  ) THEN RAISE EXCEPTION 'EMERGENCY_SESSION_NOT_ACTIVE'; END IF;

  SELECT * INTO v_existing
  FROM public.emergency_fulfillment_events WHERE event_id = p_event_id;
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

  IF (p_action = 'kitchen_started' AND v_assignment.station_type <> 'kitchen')
     OR (p_action = 'tray_ready' AND v_assignment.station_type <> 'tray')
     OR (p_action = 'floor_served' AND (
       v_assignment.station_type <> 'floor'
       OR v_assignment.floor_label <> v_queue.floor_label)) THEN
    RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN';
  END IF;

  v_started := v_item.kitchen_started_quantity
    + CASE WHEN p_action = 'kitchen_started' THEN p_delta ELSE 0 END;
  v_ready := v_item.kitchen_done_quantity
    + CASE WHEN p_action = 'tray_ready' THEN p_delta ELSE 0 END;
  v_received := v_item.tray_received_quantity
    + CASE WHEN p_action = 'tray_ready' THEN p_delta ELSE 0 END;
  v_dispatched := v_item.tray_dispatched_quantity
    + CASE WHEN p_action = 'tray_ready' THEN p_delta ELSE 0 END;
  v_served := v_item.floor_served_quantity
    + CASE WHEN p_action = 'floor_served' THEN p_delta ELSE 0 END;
  v_required := v_item.ordered_quantity - v_item.excused_quantity;
  IF v_served < 0 OR v_served > v_dispatched
     OR v_dispatched <> v_received OR v_received <> v_ready
     OR v_ready < 0 OR v_ready > v_started
     OR v_started < 0 OR v_started > v_required THEN
    RAISE EXCEPTION 'EMERGENCY_QUANTITY_CHAIN_VIOLATION';
  END IF;

  IF p_action = 'tray_ready' AND p_delta > 0 THEN
    v_sequence := public.emergency_next_floor_ready_sequence(
      v_item.restaurant_id
    );
    INSERT INTO public.emergency_floor_ready_lots (
      restaurant_id, session_id, queue_id, order_id, order_item_id,
      source_kind, source_id, ready_action_id, ready_sequence, ready_quantity
    ) VALUES (
      v_item.restaurant_id, v_item.session_id, v_item.queue_id,
      v_item.order_id, v_item.order_item_id, p_source_kind, v_item.id,
      p_event_id, v_sequence, 1
    );
  ELSIF p_action = 'tray_ready' AND p_delta < 0 THEN
    SELECT * INTO v_lot FROM public.emergency_floor_ready_lots lot
    WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
      AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity
    ORDER BY lot.ready_sequence DESC, lot.id DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KDS_READY_LOT_MISSING'; END IF;
    UPDATE public.emergency_floor_ready_lots
    SET voided_quantity = voided_quantity + 1, updated_at = now()
    WHERE id = v_lot.id;
  ELSIF p_action = 'floor_served' AND p_delta > 0 THEN
    SELECT * INTO v_lot FROM public.emergency_floor_ready_lots lot
    WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
      AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity
    ORDER BY lot.ready_sequence, lot.id LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KDS_READY_LOT_MISSING'; END IF;
    UPDATE public.emergency_floor_ready_lots
    SET served_quantity = served_quantity + 1, updated_at = now()
    WHERE id = v_lot.id;
  ELSIF p_action = 'floor_served' AND p_delta < 0 THEN
    SELECT * INTO v_lot FROM public.emergency_floor_ready_lots lot
    WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
      AND lot.served_quantity > 0
    ORDER BY lot.ready_sequence DESC, lot.id DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KDS_SERVED_LOT_MISSING'; END IF;
    UPDATE public.emergency_floor_ready_lots
    SET served_quantity = served_quantity - 1, updated_at = now()
    WHERE id = v_lot.id;
  END IF;

  IF p_source_kind = 'combo_component' THEN
    UPDATE public.emergency_combo_component_items
    SET kitchen_started_quantity = v_started,
        kitchen_done_quantity = v_ready,
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
      CASE p_action
        WHEN 'kitchen_started' THEN component.kitchen_started_quantity
        WHEN 'tray_ready' THEN component.kitchen_done_quantity
        ELSE component.floor_served_quantity
      END * v_parent.ordered_quantity / component.ordered_quantity
    ), 0)::integer INTO v_parent_value
    FROM public.emergency_combo_component_items component
    WHERE component.session_id = v_item.session_id
      AND component.order_item_id = v_item.order_item_id
      AND component.is_cancelled = false;
    UPDATE public.emergency_fulfillment_items SET
      kitchen_started_quantity = CASE WHEN p_action = 'kitchen_started'
        THEN v_parent_value ELSE kitchen_started_quantity END,
      kitchen_done_quantity = CASE WHEN p_action = 'tray_ready'
        THEN v_parent_value ELSE kitchen_done_quantity END,
      tray_received_quantity = CASE WHEN p_action = 'tray_ready'
        THEN v_parent_value ELSE tray_received_quantity END,
      tray_dispatched_quantity = CASE WHEN p_action = 'tray_ready'
        THEN v_parent_value ELSE tray_dispatched_quantity END,
      floor_served_quantity = CASE WHEN p_action = 'floor_served'
        THEN v_parent_value ELSE floor_served_quantity END,
      updated_at = now()
    WHERE id = v_parent.id;
  ELSE
    UPDATE public.emergency_fulfillment_items
    SET kitchen_started_quantity = v_started,
        kitchen_done_quantity = v_ready,
        tray_received_quantity = v_received,
        tray_dispatched_quantity = v_dispatched,
        floor_served_quantity = v_served,
        updated_at = now()
    WHERE id = v_item.id;
  END IF;

  SELECT min(lot.ready_sequence) INTO v_sequence
  FROM public.emergency_floor_ready_lots lot
  WHERE lot.source_kind = p_source_kind AND lot.source_id = v_item.id
    AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity;
  v_response := jsonb_build_object(
    'kitchen_started_quantity', v_started,
    'kitchen_done_quantity', v_ready,
    'tray_received_quantity', v_received,
    'tray_dispatched_quantity', v_dispatched,
    'floor_served_quantity', v_served,
    'oldest_ready_sequence', v_sequence
  );
  INSERT INTO public.emergency_fulfillment_events (
    event_id, session_id, restaurant_id, order_id, order_item_id,
    combo_component_item_id, stage, delta, actor_user_id, details
  ) VALUES (
    p_event_id, v_item.session_id, v_item.restaurant_id, v_item.order_id,
    v_item.order_item_id,
    CASE WHEN p_source_kind = 'combo_component' THEN v_item.id END,
    p_action, p_delta, v_user.id,
    jsonb_build_object(
      'workflow_action', p_action, 'source_kind', p_source_kind,
      'source_id', v_item.id, 'response', v_response
    )
  );
  IF p_action = 'tray_ready' AND p_delta > 0 THEN
    PERFORM public.emergency_enqueue_push(
      p_event_id, v_item.restaurant_id, v_item.order_id,
      'floor', v_queue.floor_label, p_action
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

CREATE OR REPLACE FUNCTION public.kds_serve_ready_order_v3(
  p_queue_id uuid,
  p_action_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_existing public.emergency_fulfillment_actions%ROWTYPE;
  v_line record;
  v_changed integer := 0;
BEGIN
  IF p_queue_id IS NULL OR p_action_id IS NULL THEN
    RAISE EXCEPTION 'KDS_WORKFLOW_INPUT_INVALID';
  END IF;
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment FROM public.emergency_station_assignments
  WHERE user_id = v_user.id AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND OR v_assignment.station_type <> 'floor' THEN
    RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN';
  END IF;
  SELECT * INTO v_queue FROM public.emergency_order_queue
  WHERE id = p_queue_id FOR UPDATE;
  IF NOT FOUND OR v_queue.restaurant_id <> v_assignment.restaurant_id
     OR v_queue.floor_label <> v_assignment.floor_label
     OR v_queue.workflow_version <> 2 THEN
    RAISE EXCEPTION 'EMERGENCY_QUEUE_UNAVAILABLE';
  END IF;
  SELECT * INTO v_existing FROM public.emergency_fulfillment_actions
  WHERE action_id = p_action_id;
  IF FOUND THEN
    IF v_existing.queue_id <> p_queue_id OR v_existing.station_type <> 'floor'
       OR v_existing.action_kind <> 'complete' THEN
      RAISE EXCEPTION 'KDS_EVENT_ID_CONFLICT';
    END IF;
    RETURN jsonb_build_object(
      'action_id', p_action_id, 'deduplicated', true,
      'changed_quantity', 0
    );
  END IF;
  INSERT INTO public.emergency_fulfillment_actions (
    action_id, session_id, restaurant_id, queue_id, order_id,
    station_type, floor_label, action_kind, stage, actor_user_id
  ) VALUES (
    p_action_id, v_queue.session_id, v_queue.restaurant_id, v_queue.id,
    v_queue.order_id, 'floor', v_queue.floor_label, 'complete',
    'floor_served', v_user.id
  );
  FOR v_line IN
    SELECT 'base'::text AS source_kind, item.id,
      item.tray_dispatched_quantity - item.floor_served_quantity AS pending
    FROM public.emergency_fulfillment_items item
    WHERE item.queue_id = v_queue.id AND item.is_cancelled = false
      AND item.needs_review = false
      AND NOT EXISTS (
        SELECT 1 FROM public.emergency_combo_component_items component
        WHERE component.session_id = item.session_id
          AND component.order_item_id = item.order_item_id
          AND component.is_cancelled = false
      )
    UNION ALL
    SELECT 'combo_component', component.id,
      component.tray_dispatched_quantity - component.floor_served_quantity
    FROM public.emergency_combo_component_items component
    WHERE component.queue_id = v_queue.id AND component.is_cancelled = false
      AND component.needs_review = false
    ORDER BY source_kind, id
  LOOP
    IF v_line.pending <= 0 THEN CONTINUE; END IF;
    FOR v_index IN 1..v_line.pending LOOP
      PERFORM public.kds_record_station_progress_v3(
        v_line.id, v_line.source_kind, 'floor_served', 1,
        gen_random_uuid()
      );
      v_changed := v_changed + 1;
    END LOOP;
  END LOOP;
  RETURN jsonb_build_object(
    'action_id', p_action_id, 'deduplicated', false,
    'changed_quantity', v_changed
  );
END;
$$;

REVOKE ALL ON FUNCTION public.kds_serve_ready_order_v3(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.kds_serve_ready_order_v3(uuid, uuid)
  TO authenticated;

-- Preserve delivery facts when legacy whole-item/order cancellation endpoints
-- are called directly. Fully unserved orders keep their established financial
-- cancellation and restoration behavior.
ALTER FUNCTION public.cancel_order_item(uuid, uuid)
  RENAME TO cancel_order_item_pre_start_ready;
REVOKE ALL ON FUNCTION public.cancel_order_item_pre_start_ready(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.cancel_order_item(
  p_item_id uuid,
  p_store_id uuid
) RETURNS public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items item
    WHERE item.order_item_id = p_item_id AND item.floor_served_quantity > 0
    UNION ALL
    SELECT 1 FROM public.emergency_combo_component_items component
    WHERE component.order_item_id = p_item_id
      AND component.floor_served_quantity > 0
    UNION ALL
    SELECT 1 FROM public.emergency_floor_direct_items direct_item
    WHERE direct_item.order_item_id = p_item_id
      AND direct_item.floor_served_quantity > 0
  ) THEN
    RAISE EXCEPTION 'ITEM_HAS_SERVED_QUANTITY_USE_UNSERVED_CANCELLATION';
  END IF;
  RETURN public.cancel_order_item_pre_start_ready(p_item_id, p_store_id);
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_order_item(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_order_item(uuid, uuid)
  TO authenticated;

ALTER FUNCTION public.cancel_order(uuid, uuid, boolean)
  RENAME TO cancel_order_pre_start_ready;
REVOKE ALL ON FUNCTION public.cancel_order_pre_start_ready(uuid, uuid, boolean)
  FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.cancel_order(
  p_order_id uuid,
  p_store_id uuid,
  p_allow_served boolean DEFAULT false
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items item
    WHERE item.order_id = p_order_id AND item.floor_served_quantity > 0
    UNION ALL
    SELECT 1 FROM public.emergency_combo_component_items component
    WHERE component.order_id = p_order_id
      AND component.floor_served_quantity > 0
    UNION ALL
    SELECT 1 FROM public.emergency_floor_direct_items direct_item
    WHERE direct_item.order_id = p_order_id
      AND direct_item.floor_served_quantity > 0
  ) THEN
    RAISE EXCEPTION 'ORDER_HAS_SERVED_QUANTITY_CANCEL_UNSERVED_ITEMS';
  END IF;
  RETURN public.cancel_order_pre_start_ready(
    p_order_id, p_store_id, p_allow_served
  );
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_order(uuid, uuid, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_order(uuid, uuid, boolean)
  TO authenticated;

CREATE TABLE public.emergency_unserved_cancellations (
  request_id uuid PRIMARY KEY,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id)
    ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  order_item_id uuid NOT NULL REFERENCES public.order_items(id)
    ON DELETE CASCADE,
  quantity integer NOT NULL CHECK (quantity > 0),
  reason text NOT NULL CHECK (length(btrim(reason)) >= 3),
  cancellation_kind text NOT NULL CHECK (cancellation_kind IN (
    'financial_full', 'fulfillment_only'
  )),
  response jsonb NOT NULL,
  created_by uuid NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX emergency_unserved_cancellations_order
  ON public.emergency_unserved_cancellations
  (restaurant_id, order_id, created_at DESC);
ALTER TABLE public.emergency_unserved_cancellations ENABLE ROW LEVEL SECURITY;
CREATE POLICY emergency_unserved_cancellations_store_read
ON public.emergency_unserved_cancellations
FOR SELECT TO authenticated
USING (public.is_super_admin() OR EXISTS (
  SELECT 1
  FROM public.user_accessible_stores((SELECT auth.uid())) scope(store_id)
  WHERE scope.store_id = restaurant_id
));
REVOKE ALL ON public.emergency_unserved_cancellations
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.emergency_unserved_cancellations TO authenticated;
GRANT ALL ON public.emergency_unserved_cancellations TO service_role;

CREATE OR REPLACE FUNCTION public.emergency_void_latest_ready_lots(
  p_source_kind text,
  p_source_id uuid,
  p_quantity integer
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE v_lot public.emergency_floor_ready_lots%ROWTYPE;
  v_remaining integer := p_quantity;
  v_delta integer;
BEGIN
  WHILE v_remaining > 0 LOOP
    SELECT * INTO v_lot FROM public.emergency_floor_ready_lots lot
    WHERE lot.source_kind = p_source_kind AND lot.source_id = p_source_id
      AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity
    ORDER BY lot.ready_sequence DESC, lot.id DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KDS_READY_LOT_MISSING'; END IF;
    v_delta := LEAST(
      v_remaining,
      v_lot.ready_quantity - v_lot.served_quantity - v_lot.voided_quantity
    );
    UPDATE public.emergency_floor_ready_lots
    SET voided_quantity = voided_quantity + v_delta, updated_at = now()
    WHERE id = v_lot.id;
    v_remaining := v_remaining - v_delta;
  END LOOP;
  RETURN p_quantity;
END;
$$;
REVOKE ALL ON FUNCTION public.emergency_void_latest_ready_lots(
  text, uuid, integer
) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.cashier_cancel_unserved_v1(
  p_item_id uuid,
  p_store_id uuid,
  p_quantity integer,
  p_reason text,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_existing public.emergency_unserved_cancellations%ROWTYPE;
  v_base public.emergency_fulfillment_items%ROWTYPE;
  v_component public.emergency_combo_component_items%ROWTYPE;
  v_direct public.emergency_floor_direct_items%ROWTYPE;
  v_has_combo boolean;
  v_has_payment boolean;
  v_any_served boolean;
  v_available integer := 0;
  v_remaining integer := p_quantity;
  v_line_cancel integer;
  v_new_required integer;
  v_new_started integer;
  v_new_ready integer;
  v_void integer;
  v_event_id uuid;
  v_response jsonb;
BEGIN
  IF p_item_id IS NULL OR p_store_id IS NULL OR p_request_id IS NULL
     OR p_quantity IS NULL OR p_quantity <= 0
     OR length(btrim(COALESCE(p_reason, ''))) < 3 THEN
    RAISE EXCEPTION 'UNSERVED_CANCELLATION_INPUT_INVALID';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  SELECT * INTO v_existing FROM public.emergency_unserved_cancellations
  WHERE request_id = p_request_id;
  IF FOUND THEN RETURN v_existing.response || jsonb_build_object(
    'deduplicated', true
  ); END IF;

  SELECT * INTO v_actor FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN'; END IF;
  IF NOT public.is_super_admin() AND NOT EXISTS (
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = p_store_id
  ) THEN RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN'; END IF;

  SELECT * INTO v_item FROM public.order_items
  WHERE id = p_item_id AND restaurant_id = p_store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND'; END IF;
  PERFORM 1 FROM public.orders order_row
  WHERE order_row.id = v_item.order_id
    AND order_row.status NOT IN ('completed', 'cancelled') FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_MUTABLE'; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.emergency_combo_component_items component
    WHERE component.order_item_id = p_item_id
      AND component.is_cancelled = false
  ) INTO v_has_combo;
  SELECT EXISTS (
    SELECT 1 FROM public.payments payment WHERE payment.order_id = v_item.order_id
  ) INTO v_has_payment;
  SELECT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items line
    WHERE line.order_item_id = p_item_id AND line.floor_served_quantity > 0
    UNION ALL
    SELECT 1 FROM public.emergency_combo_component_items line
    WHERE line.order_item_id = p_item_id AND line.floor_served_quantity > 0
    UNION ALL
    SELECT 1 FROM public.emergency_floor_direct_items line
    WHERE line.order_item_id = p_item_id AND line.floor_served_quantity > 0
  ) INTO v_any_served;

  SELECT COALESCE(sum(required_quantity - served_quantity), 0)::integer
  INTO v_available
  FROM (
    SELECT line.ordered_quantity - line.excused_quantity AS required_quantity,
      line.floor_served_quantity AS served_quantity
    FROM public.emergency_fulfillment_items line
    WHERE line.order_item_id = p_item_id AND line.is_cancelled = false
    UNION ALL
    SELECT line.ordered_quantity - line.excused_quantity,
      line.floor_served_quantity
    FROM public.emergency_floor_direct_items line
    WHERE line.order_item_id = p_item_id AND line.is_cancelled = false
  ) presented;
  IF p_quantity > v_available OR v_available <= 0 THEN
    RAISE EXCEPTION 'UNSERVED_CANCELLATION_QUANTITY_INVALID';
  END IF;
  IF v_has_combo AND p_quantity <> v_available THEN
    RAISE EXCEPTION 'COMBO_UNSERVED_CANCELLATION_MUST_CLOSE_REMAINDER';
  END IF;

  IF NOT v_has_payment AND NOT v_any_served AND p_quantity = v_available THEN
    PERFORM public.cancel_order_item_pre_start_ready(p_item_id, p_store_id);
    v_response := jsonb_build_object(
      'request_id', p_request_id, 'order_id', v_item.order_id,
      'order_item_id', p_item_id, 'cancelled_quantity', p_quantity,
      'cancellation_kind', 'financial_full', 'deduplicated', false
    );
    INSERT INTO public.emergency_unserved_cancellations (
      request_id, restaurant_id, order_id, order_item_id, quantity, reason,
      cancellation_kind, response, created_by
    ) VALUES (
      p_request_id, p_store_id, v_item.order_id, p_item_id, p_quantity,
      btrim(p_reason), 'financial_full', v_response, v_actor.id
    );
    RETURN v_response;
  END IF;

  SELECT * INTO v_base FROM public.emergency_fulfillment_items line
  WHERE line.order_item_id = p_item_id AND line.is_cancelled = false
  FOR UPDATE;
  IF FOUND AND v_remaining > 0 THEN
    v_line_cancel := LEAST(
      v_remaining,
      v_base.ordered_quantity - v_base.excused_quantity
        - v_base.floor_served_quantity
    );
    IF v_line_cancel > 0 THEN
      v_new_required := v_base.ordered_quantity - v_base.excused_quantity
        - v_line_cancel;
      v_new_ready := LEAST(v_base.kitchen_done_quantity, v_new_required);
      v_new_started := LEAST(v_base.kitchen_started_quantity, v_new_required);
      v_void := v_base.kitchen_done_quantity - v_new_ready;
      IF v_void > 0 THEN
        PERFORM public.emergency_void_latest_ready_lots(
          'base', v_base.id, v_void
        );
      END IF;
      UPDATE public.emergency_fulfillment_items SET
        excused_quantity = excused_quantity + v_line_cancel,
        kitchen_started_quantity = v_new_started,
        kitchen_done_quantity = v_new_ready,
        tray_received_quantity = v_new_ready,
        tray_dispatched_quantity = v_new_ready,
        updated_at = now()
      WHERE id = v_base.id;
      v_event_id := gen_random_uuid();
      INSERT INTO public.emergency_fulfillment_events (
        event_id, session_id, restaurant_id, order_id, order_item_id,
        stage, delta, actor_user_id, details
      ) VALUES (
        v_event_id, v_base.session_id, p_store_id, v_item.order_id, p_item_id,
        'fulfillment_cancelled', v_line_cancel, v_actor.id,
        jsonb_build_object('request_id', p_request_id, 'reason', btrim(p_reason),
          'source_kind', 'base', 'source_id', v_base.id)
      );
      v_remaining := v_remaining - v_line_cancel;
    END IF;
  END IF;

  IF v_has_combo THEN
    FOR v_component IN
      SELECT * FROM public.emergency_combo_component_items component
      WHERE component.order_item_id = p_item_id
        AND component.is_cancelled = false
      ORDER BY component.id FOR UPDATE
    LOOP
      v_line_cancel := v_component.ordered_quantity
        - v_component.excused_quantity - v_component.floor_served_quantity;
      IF v_line_cancel <= 0 THEN CONTINUE; END IF;
      v_new_required := v_component.floor_served_quantity;
      v_void := v_component.kitchen_done_quantity - v_new_required;
      IF v_void > 0 THEN
        PERFORM public.emergency_void_latest_ready_lots(
          'combo_component', v_component.id, v_void
        );
      END IF;
      UPDATE public.emergency_combo_component_items SET
        excused_quantity = ordered_quantity - floor_served_quantity,
        kitchen_started_quantity = floor_served_quantity,
        kitchen_done_quantity = floor_served_quantity,
        tray_received_quantity = floor_served_quantity,
        tray_dispatched_quantity = floor_served_quantity,
        updated_at = now()
      WHERE id = v_component.id;
      v_event_id := gen_random_uuid();
      INSERT INTO public.emergency_fulfillment_events (
        event_id, session_id, restaurant_id, order_id, order_item_id,
        combo_component_item_id, stage, delta, actor_user_id, details
      ) VALUES (
        v_event_id, v_component.session_id, p_store_id, v_item.order_id,
        p_item_id, v_component.id, 'fulfillment_cancelled', v_line_cancel,
        v_actor.id, jsonb_build_object('request_id', p_request_id,
          'reason', btrim(p_reason), 'source_kind', 'combo_component',
          'source_id', v_component.id)
      );
    END LOOP;
  END IF;

  FOR v_direct IN
    SELECT * FROM public.emergency_floor_direct_items direct_item
    WHERE direct_item.order_item_id = p_item_id
      AND direct_item.is_cancelled = false
    ORDER BY direct_item.id FOR UPDATE
  LOOP
    EXIT WHEN v_remaining <= 0;
    v_line_cancel := LEAST(
      v_remaining,
      v_direct.ordered_quantity - v_direct.excused_quantity
        - v_direct.floor_served_quantity
    );
    IF v_line_cancel <= 0 THEN CONTINUE; END IF;
    UPDATE public.emergency_floor_direct_items
    SET excused_quantity = excused_quantity + v_line_cancel, updated_at = now()
    WHERE id = v_direct.id;
    v_event_id := gen_random_uuid();
    INSERT INTO public.emergency_fulfillment_events (
      event_id, session_id, restaurant_id, order_id, order_item_id,
      floor_direct_item_id, stage, delta, actor_user_id, details
    ) VALUES (
      v_event_id, v_direct.session_id, p_store_id, v_item.order_id, p_item_id,
      v_direct.id, 'fulfillment_cancelled', v_line_cancel, v_actor.id,
      jsonb_build_object('request_id', p_request_id, 'reason', btrim(p_reason),
        'source_kind', 'floor_direct', 'source_id', v_direct.id)
    );
    v_remaining := v_remaining - v_line_cancel;
  END LOOP;
  IF v_remaining <> 0 THEN
    RAISE EXCEPTION 'UNSERVED_CANCELLATION_ALLOCATION_FAILED';
  END IF;

  v_response := jsonb_build_object(
    'request_id', p_request_id, 'order_id', v_item.order_id,
    'order_item_id', p_item_id, 'cancelled_quantity', p_quantity,
    'cancellation_kind', 'fulfillment_only', 'deduplicated', false
  );
  INSERT INTO public.emergency_unserved_cancellations (
    request_id, restaurant_id, order_id, order_item_id, quantity, reason,
    cancellation_kind, response, created_by
  ) VALUES (
    p_request_id, p_store_id, v_item.order_id, p_item_id, p_quantity,
    btrim(p_reason), 'fulfillment_only', v_response, v_actor.id
  );
  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'cancel_unserved_fulfillment', 'order_items', p_item_id,
    v_response || jsonb_build_object('reason', btrim(p_reason))
  );
  RETURN v_response;
END;
$$;
REVOKE ALL ON FUNCTION public.cashier_cancel_unserved_v1(
  uuid, uuid, integer, text, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cashier_cancel_unserved_v1(
  uuid, uuid, integer, text, uuid
) TO authenticated;

-- The existing v2 capture trigger creates the durable revision. Correct its
-- station fanout before the deferred broadcast reads the row at commit.
CREATE OR REPLACE FUNCTION public.kds_set_workflow_event_targets()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_delivery boolean := false;
  v_targets text[];
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
    WHEN 'tray_ready' THEN CASE WHEN v_delivery
      THEN ARRAY['tray']::text[]
      ELSE ARRAY['kitchen', 'tray', 'floor']::text[] END
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
DROP TRIGGER IF EXISTS zzz_kds_set_workflow_event_targets_trigger
  ON public.emergency_fulfillment_events;
CREATE TRIGGER zzz_kds_set_workflow_event_targets_trigger
AFTER INSERT ON public.emergency_fulfillment_events
FOR EACH ROW EXECUTE FUNCTION public.kds_set_workflow_event_targets();

-- Add workflow data after every established localization/combo/timing wrapper.
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
  v_sequence bigint;
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
      v_started := NULL;
      v_excused := 0;
      v_sequence := NULL;
      IF v_item->>'source_kind' = 'combo_component' THEN
        SELECT component.kitchen_started_quantity, component.excused_quantity
        INTO v_started, v_excused
        FROM public.emergency_combo_component_items component
        WHERE component.id = NULLIF(v_item->>'id', '')::uuid;
        SELECT min(lot.ready_sequence) INTO v_sequence
        FROM public.emergency_floor_ready_lots lot
        WHERE lot.source_kind = 'combo_component'
          AND lot.source_id = NULLIF(v_item->>'id', '')::uuid
          AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity;
      ELSIF COALESCE(v_item->>'fulfillment_route', '') <> 'floor_direct' THEN
        SELECT item.kitchen_started_quantity, item.excused_quantity
        INTO v_started, v_excused
        FROM public.emergency_fulfillment_items item
        WHERE item.id = NULLIF(v_item->>'id', '')::uuid;
        SELECT min(lot.ready_sequence) INTO v_sequence
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
            - COALESCE(v_excused, 0),
          0
        ),
        'oldest_ready_sequence', v_sequence
      ));
    END LOOP;
    SELECT min(lot.ready_sequence) INTO v_sequence
    FROM public.emergency_floor_ready_lots lot
    WHERE lot.queue_id = NULLIF(v_order->>'queue_id', '')::uuid
      AND lot.served_quantity + lot.voided_quantity < lot.ready_quantity;
    v_result := v_result || jsonb_build_array(
      jsonb_set(v_order, '{items}', v_items, true) || jsonb_build_object(
        'workflow_version', v_workflow,
        'oldest_ready_sequence', v_sequence
      )
    );
  END LOOP;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb)
  FROM PUBLIC, anon, authenticated;

ALTER FUNCTION public.get_emergency_station_snapshot()
  RENAME TO get_emergency_station_snapshot_pre_start_ready;
REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot_pre_start_ready()
  FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.get_emergency_station_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE v_payload jsonb;
BEGIN
  v_payload := public.get_emergency_station_snapshot_pre_start_ready();
  IF jsonb_typeof(v_payload) = 'object' AND v_payload ? 'orders' THEN
    v_payload := jsonb_set(v_payload, '{orders}',
      public.emergency_enrich_start_ready_orders(v_payload->'orders'), true);
  END IF;
  RETURN v_payload;
END;
$$;
REVOKE ALL ON FUNCTION public.get_emergency_station_snapshot()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_snapshot()
  TO authenticated;

ALTER FUNCTION public.get_emergency_station_today_completed()
  RENAME TO get_emergency_station_today_completed_pre_start_ready;
REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed_pre_start_ready()
  FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.get_emergency_station_today_completed()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
  SELECT public.emergency_enrich_start_ready_orders(
    public.get_emergency_station_today_completed_pre_start_ready()
  );
$$;
REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_today_completed()
  TO authenticated;

ALTER FUNCTION public.get_kds_ticket_v2(uuid)
  RENAME TO get_kds_ticket_v2_pre_start_ready;
REVOKE ALL ON FUNCTION public.get_kds_ticket_v2_pre_start_ready(uuid)
  FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.get_kds_ticket_v2(p_queue_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE v_result jsonb; v_ticket jsonb;
BEGIN
  v_result := public.get_kds_ticket_v2_pre_start_ready(p_queue_id);
  v_ticket := NULLIF(v_result->'ticket', 'null'::jsonb);
  IF v_ticket IS NOT NULL THEN
    v_result := jsonb_set(v_result, '{ticket}',
      public.emergency_enrich_start_ready_orders(
        jsonb_build_array(v_ticket)
      )->0, true);
  END IF;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_kds_ticket_v2(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_kds_ticket_v2(uuid)
  TO authenticated;

ALTER FUNCTION public.get_emergency_order_summaries(uuid[])
  RENAME TO get_emergency_order_summaries_pre_start_ready;
REVOKE ALL ON FUNCTION public.get_emergency_order_summaries_pre_start_ready(
  uuid[]
) FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.get_emergency_order_summaries(
  p_order_ids uuid[]
) RETURNS TABLE (
  order_id uuid,
  emergency_active boolean,
  unserved_quantity integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  IF p_order_ids IS NULL OR cardinality(p_order_ids) = 0 THEN RETURN; END IF;
  RETURN QUERY
  WITH progress AS (
    SELECT item.order_id, item.restaurant_id, item.session_id,
      item.ordered_quantity - item.excused_quantity AS required_quantity,
      item.floor_served_quantity, item.is_cancelled
    FROM public.emergency_fulfillment_items item
    UNION ALL
    SELECT item.order_id, item.restaurant_id, item.session_id,
      item.ordered_quantity - item.excused_quantity,
      item.floor_served_quantity, item.is_cancelled
    FROM public.emergency_floor_direct_items item
  )
  SELECT progress.order_id, true,
    COALESCE(sum(
      progress.required_quantity - progress.floor_served_quantity
    ), 0)::integer
  FROM progress
  JOIN public.emergency_fulfillment_sessions session
    ON session.id = progress.session_id
  WHERE progress.order_id = ANY(p_order_ids)
    AND session.status = 'active'
    AND progress.is_cancelled = false
    AND (public.is_super_admin() OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores((SELECT auth.uid())) scope(store_id)
      WHERE scope.store_id = progress.restaurant_id
    ))
  GROUP BY progress.order_id;
END;
$$;
REVOKE ALL ON FUNCTION public.get_emergency_order_summaries(uuid[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_order_summaries(uuid[])
  TO authenticated;

ALTER FUNCTION public.get_emergency_order_item_progress(uuid[])
  RENAME TO get_emergency_order_item_progress_pre_start_ready;
REVOKE ALL ON FUNCTION public.get_emergency_order_item_progress_pre_start_ready(
  uuid[]
) FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.get_emergency_order_item_progress(
  p_order_ids uuid[]
) RETURNS TABLE (
  order_id uuid,
  order_item_id uuid,
  fulfillment_item_id uuid,
  line_key text,
  source_kind text,
  fulfillment_route text,
  name_ko text,
  name_vi text,
  name_en text,
  ordered_quantity integer,
  floor_served_quantity integer,
  excused_quantity integer,
  required_quantity integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
  SELECT progress.order_id, progress.order_item_id,
    progress.fulfillment_item_id, progress.line_key, progress.source_kind,
    progress.fulfillment_route, progress.name_ko, progress.name_vi,
    progress.name_en, progress.ordered_quantity,
    progress.floor_served_quantity,
    COALESCE(base.excused_quantity, direct_item.excused_quantity, 0)::integer,
    GREATEST(
      progress.ordered_quantity
        - COALESCE(base.excused_quantity, direct_item.excused_quantity, 0),
      0
    )::integer
  FROM public.get_emergency_order_item_progress_pre_start_ready(
    p_order_ids
  ) progress
  LEFT JOIN public.emergency_fulfillment_items base
    ON progress.fulfillment_route <> 'floor_direct'
   AND base.id = progress.fulfillment_item_id
  LEFT JOIN public.emergency_floor_direct_items direct_item
    ON progress.fulfillment_route = 'floor_direct'
   AND direct_item.id = progress.fulfillment_item_id;
$$;
REVOKE ALL ON FUNCTION public.get_emergency_order_item_progress(uuid[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_order_item_progress(uuid[])
  TO authenticated;

CREATE OR REPLACE FUNCTION public.emergency_enrich_qr_unserved_items(
  p_order_id uuid,
  p_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_result jsonb := '[]'::jsonb;
  v_item jsonb;
  v_part jsonb;
  v_parts jsonb;
  v_order_item_id uuid;
  v_required integer;
  v_excused integer;
  v_index bigint;
BEGIN
  IF jsonb_typeof(p_items) <> 'array' THEN RETURN '[]'::jsonb; END IF;
  FOR v_item, v_index IN
    SELECT value, ordinality
    FROM jsonb_array_elements(p_items) WITH ORDINALITY
  LOOP
    SELECT order_item.id INTO v_order_item_id
    FROM public.order_items order_item
    WHERE order_item.order_id = p_order_id
      AND order_item.status <> 'cancelled'
      AND order_item.item_type = 'menu_item'
      AND COALESCE(order_item.is_service_item, false) = false
    ORDER BY order_item.created_at, order_item.id
    OFFSET v_index - 1 LIMIT 1;
    IF v_order_item_id IS NULL THEN
      v_result := v_result || jsonb_build_array(v_item);
      CONTINUE;
    END IF;
    SELECT COALESCE(
      (SELECT base.ordered_quantity - base.excused_quantity
       FROM public.emergency_fulfillment_items base
       WHERE base.order_item_id = v_order_item_id AND base.is_cancelled = false
       ORDER BY base.created_at DESC LIMIT 1),
      (SELECT direct_item.ordered_quantity - direct_item.excused_quantity
       FROM public.emergency_floor_direct_items direct_item
       WHERE direct_item.order_item_id = v_order_item_id
         AND direct_item.line_key = 'base'
         AND direct_item.is_cancelled = false
       ORDER BY direct_item.created_at DESC LIMIT 1),
      COALESCE((v_item->>'quantity')::integer, 0)
    ) INTO v_required;
    v_parts := '[]'::jsonb;
    FOR v_part IN SELECT value FROM jsonb_array_elements(
      COALESCE(v_item->'fulfillment_parts', '[]'::jsonb)
    ) LOOP
      v_excused := 0;
      IF COALESCE(v_part->>'fulfillment_route', '') = 'floor_direct' THEN
        SELECT COALESCE(direct_item.excused_quantity, 0) INTO v_excused
        FROM public.emergency_floor_direct_items direct_item
        WHERE direct_item.order_item_id = v_order_item_id
          AND direct_item.line_key = COALESCE(v_part->>'line_key', 'base')
          AND direct_item.is_cancelled = false
        ORDER BY direct_item.created_at DESC LIMIT 1;
      ELSE
        SELECT COALESCE(base.excused_quantity, 0) INTO v_excused
        FROM public.emergency_fulfillment_items base
        WHERE base.order_item_id = v_order_item_id AND base.is_cancelled = false
        ORDER BY base.created_at DESC LIMIT 1;
      END IF;
      v_parts := v_parts || jsonb_build_array(jsonb_set(
        v_part, '{quantity}', to_jsonb(GREATEST(
          COALESCE((v_part->>'quantity')::integer, 0)
            - COALESCE(v_excused, 0), 0
        )), true
      ));
    END LOOP;
    v_item := jsonb_set(v_item, '{quantity}', to_jsonb(v_required), true);
    v_item := jsonb_set(v_item, '{fulfillment_parts}', v_parts, true);
    v_result := v_result || jsonb_build_array(v_item);
  END LOOP;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.emergency_enrich_qr_unserved_items(uuid, jsonb)
  FROM PUBLIC, anon, authenticated;

ALTER FUNCTION public.qr_get_active_order(text)
  RENAME TO qr_get_active_order_pre_start_ready;
REVOKE ALL ON FUNCTION public.qr_get_active_order_pre_start_ready(text)
  FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.qr_get_active_order(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_result jsonb;
  v_order_id uuid;
BEGIN
  v_result := public.qr_get_active_order_pre_start_ready(p_token);
  IF COALESCE((v_result->>'active')::boolean, false) = false THEN
    RETURN v_result;
  END IF;
  SELECT order_row.id INTO v_order_id
  FROM public.table_qr_tokens token
  JOIN public.orders order_row
    ON order_row.restaurant_id = token.restaurant_id
   AND order_row.table_id = token.table_id
   AND order_row.status IN ('pending', 'confirmed', 'serving')
  WHERE token.token = NULLIF(btrim(COALESCE(p_token, '')), '')
    AND token.is_active = true
  ORDER BY order_row.created_at DESC LIMIT 1;
  IF v_order_id IS NOT NULL THEN
    v_result := jsonb_set(v_result, '{items}',
      public.emergency_enrich_qr_unserved_items(
        v_order_id, COALESCE(v_result->'items', '[]'::jsonb)
      ), true);
  END IF;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.qr_get_active_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_get_active_order(text)
  TO anon, authenticated, service_role;

COMMIT;
