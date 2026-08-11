-- Order-level actions for the emergency KDS grid.
-- Additive only: the existing item-level RPC remains available for compatibility.

CREATE TABLE public.emergency_fulfillment_actions (
  action_id uuid PRIMARY KEY,
  session_id uuid NOT NULL
    REFERENCES public.emergency_fulfillment_sessions(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL
    REFERENCES public.restaurants(id) ON DELETE CASCADE,
  queue_id uuid NOT NULL
    REFERENCES public.emergency_order_queue(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  station_type text NOT NULL
    CHECK (station_type IN ('kitchen', 'tray', 'floor')),
  floor_label text,
  action_kind text NOT NULL CHECK (action_kind IN ('complete', 'revert')),
  stage text NOT NULL
    CHECK (stage IN ('kitchen_done', 'tray_handoff', 'floor_served')),
  original_action_id uuid
    REFERENCES public.emergency_fulfillment_actions(action_id) ON DELETE RESTRICT,
  actor_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT emergency_action_revert_contract CHECK (
    (action_kind = 'complete' AND original_action_id IS NULL)
    OR (action_kind = 'revert' AND original_action_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX emergency_one_revert_per_action
  ON public.emergency_fulfillment_actions (original_action_id)
  WHERE action_kind = 'revert';

CREATE INDEX emergency_actions_queue_station_recent
  ON public.emergency_fulfillment_actions (
    queue_id, station_type, created_at DESC
  );

ALTER TABLE public.emergency_fulfillment_events
  ADD COLUMN action_id uuid
    REFERENCES public.emergency_fulfillment_actions(action_id)
    ON DELETE SET NULL;

CREATE INDEX emergency_events_action
  ON public.emergency_fulfillment_events (action_id)
  WHERE action_id IS NOT NULL;

ALTER TABLE public.emergency_fulfillment_actions ENABLE ROW LEVEL SECURITY;

CREATE POLICY emergency_actions_store_read
ON public.emergency_fulfillment_actions
FOR SELECT TO authenticated
USING (public.is_super_admin() OR EXISTS (
  SELECT 1
  FROM public.user_accessible_stores(auth.uid()) scope(store_id)
  WHERE scope.store_id = restaurant_id
));

REVOKE ALL ON public.emergency_fulfillment_actions
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.emergency_fulfillment_actions TO authenticated;
GRANT ALL ON public.emergency_fulfillment_actions TO service_role;

CREATE OR REPLACE FUNCTION public.emergency_complete_order_stage(
  p_queue_id uuid,
  p_action_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_item public.emergency_fulfillment_items%ROWTYPE;
  v_existing public.emergency_fulfillment_actions%ROWTYPE;
  v_event_id uuid;
  v_push_event_id uuid;
  v_stage text;
  v_target_station text;
  v_changed integer := 0;
  v_received_delta integer;
  v_dispatched_delta integer;
  v_inserted integer;
BEGIN
  IF p_queue_id IS NULL OR p_action_id IS NULL THEN
    RAISE EXCEPTION 'EMERGENCY_ORDER_ACTION_INPUT_INVALID';
  END IF;

  SELECT * INTO v_user
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;

  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_STATION_REQUIRED'; END IF;

  SELECT queue.* INTO v_queue
  FROM public.emergency_order_queue queue
  JOIN public.emergency_fulfillment_sessions session
    ON session.id = queue.session_id AND session.status = 'active'
  WHERE queue.id = p_queue_id
  FOR UPDATE OF queue;
  IF NOT FOUND
     OR v_queue.restaurant_id <> v_assignment.restaurant_id
     OR (v_assignment.station_type = 'floor'
       AND v_assignment.floor_label <> v_queue.floor_label) THEN
    RAISE EXCEPTION 'EMERGENCY_ORDER_UNAVAILABLE';
  END IF;

  v_stage := CASE v_assignment.station_type
    WHEN 'kitchen' THEN 'kitchen_done'
    WHEN 'tray' THEN 'tray_handoff'
    WHEN 'floor' THEN 'floor_served'
  END;

  INSERT INTO public.emergency_fulfillment_actions (
    action_id, session_id, restaurant_id, queue_id, order_id,
    station_type, floor_label, action_kind, stage, actor_user_id
  ) VALUES (
    p_action_id, v_queue.session_id, v_queue.restaurant_id,
    v_queue.id, v_queue.order_id, v_assignment.station_type,
    v_assignment.floor_label, 'complete', v_stage, v_user.id
  ) ON CONFLICT (action_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT * INTO v_existing
    FROM public.emergency_fulfillment_actions
    WHERE action_id = p_action_id;
    IF v_existing.queue_id <> p_queue_id
       OR v_existing.station_type <> v_assignment.station_type
       OR v_existing.action_kind <> 'complete' THEN
      RAISE EXCEPTION 'EMERGENCY_ACTION_ID_CONFLICT';
    END IF;
    RETURN jsonb_build_object(
      'action_id', p_action_id,
      'deduplicated', true,
      'changed_quantity', 0
    );
  END IF;

  FOR v_item IN
    SELECT *
    FROM public.emergency_fulfillment_items
    WHERE queue_id = p_queue_id AND is_cancelled = false
    ORDER BY id
    FOR UPDATE
  LOOP
    IF v_assignment.station_type = 'kitchen'
       AND v_item.kitchen_done_quantity < v_item.ordered_quantity THEN
      v_changed := v_changed
        + (v_item.ordered_quantity - v_item.kitchen_done_quantity);
      v_event_id := gen_random_uuid();
      UPDATE public.emergency_fulfillment_items
      SET kitchen_done_quantity = ordered_quantity, updated_at = now()
      WHERE id = v_item.id;
      INSERT INTO public.emergency_fulfillment_events (
        event_id, session_id, restaurant_id, order_id, order_item_id,
        stage, delta, actor_user_id, action_id, details
      ) VALUES (
        v_event_id, v_item.session_id, v_item.restaurant_id,
        v_item.order_id, v_item.order_item_id, 'kitchen_done',
        v_item.ordered_quantity - v_item.kitchen_done_quantity,
        v_user.id, p_action_id, '{"order_action":true}'::jsonb
      );
      v_push_event_id := COALESCE(v_push_event_id, v_event_id);
      v_target_station := 'tray';
    ELSIF v_assignment.station_type = 'tray' THEN
      v_received_delta :=
        v_item.kitchen_done_quantity - v_item.tray_received_quantity;
      v_dispatched_delta :=
        v_item.kitchen_done_quantity - v_item.tray_dispatched_quantity;
      IF v_received_delta > 0 OR v_dispatched_delta > 0 THEN
        UPDATE public.emergency_fulfillment_items
        SET tray_received_quantity = kitchen_done_quantity,
            tray_dispatched_quantity = kitchen_done_quantity,
            updated_at = now()
        WHERE id = v_item.id;
      END IF;
      IF v_received_delta > 0 THEN
        v_event_id := gen_random_uuid();
        INSERT INTO public.emergency_fulfillment_events (
          event_id, session_id, restaurant_id, order_id, order_item_id,
          stage, delta, actor_user_id, action_id, details
        ) VALUES (
          v_event_id, v_item.session_id, v_item.restaurant_id,
          v_item.order_id, v_item.order_item_id, 'tray_received',
          v_received_delta, v_user.id, p_action_id,
          '{"order_action":true}'::jsonb
        );
      END IF;
      IF v_dispatched_delta > 0 THEN
        v_event_id := gen_random_uuid();
        INSERT INTO public.emergency_fulfillment_events (
          event_id, session_id, restaurant_id, order_id, order_item_id,
          stage, delta, actor_user_id, action_id, details
        ) VALUES (
          v_event_id, v_item.session_id, v_item.restaurant_id,
          v_item.order_id, v_item.order_item_id, 'tray_dispatched',
          v_dispatched_delta, v_user.id, p_action_id,
          '{"order_action":true}'::jsonb
        );
        v_push_event_id := COALESCE(v_push_event_id, v_event_id);
        v_target_station := 'floor';
      END IF;
      v_changed := v_changed + GREATEST(v_received_delta, v_dispatched_delta);
    ELSIF v_assignment.station_type = 'floor'
       AND v_item.floor_served_quantity < v_item.tray_dispatched_quantity THEN
      v_changed := v_changed
        + (v_item.tray_dispatched_quantity - v_item.floor_served_quantity);
      v_event_id := gen_random_uuid();
      UPDATE public.emergency_fulfillment_items
      SET floor_served_quantity = tray_dispatched_quantity,
          updated_at = now()
      WHERE id = v_item.id;
      INSERT INTO public.emergency_fulfillment_events (
        event_id, session_id, restaurant_id, order_id, order_item_id,
        stage, delta, actor_user_id, action_id, details
      ) VALUES (
        v_event_id, v_item.session_id, v_item.restaurant_id,
        v_item.order_id, v_item.order_item_id, 'floor_served',
        v_item.tray_dispatched_quantity - v_item.floor_served_quantity,
        v_user.id, p_action_id, '{"order_action":true}'::jsonb
      );
    END IF;
  END LOOP;

  IF v_changed <= 0 THEN
    RAISE EXCEPTION 'EMERGENCY_ORDER_STAGE_ALREADY_COMPLETE';
  END IF;

  IF v_push_event_id IS NOT NULL AND v_target_station IS NOT NULL THEN
    PERFORM public.emergency_enqueue_push(
      v_push_event_id, v_queue.restaurant_id, v_queue.order_id,
      v_target_station, v_queue.floor_label, v_stage
    );
  END IF;

  RETURN jsonb_build_object(
    'action_id', p_action_id,
    'deduplicated', false,
    'changed_quantity', v_changed,
    'stage', v_stage
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.emergency_revert_order_action(
  p_queue_id uuid,
  p_action_id uuid,
  p_revert_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_original public.emergency_fulfillment_actions%ROWTYPE;
  v_existing public.emergency_fulfillment_actions%ROWTYPE;
  v_item public.emergency_fulfillment_items%ROWTYPE;
  v_event RECORD;
  v_latest_action_id uuid;
  v_changed integer := 0;
  v_inserted integer;
BEGIN
  IF p_queue_id IS NULL OR p_action_id IS NULL OR p_revert_id IS NULL
     OR p_action_id = p_revert_id THEN
    RAISE EXCEPTION 'EMERGENCY_REVERT_INPUT_INVALID';
  END IF;

  SELECT * INTO v_user
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;

  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_STATION_REQUIRED'; END IF;

  SELECT queue.* INTO v_queue
  FROM public.emergency_order_queue queue
  JOIN public.emergency_fulfillment_sessions session
    ON session.id = queue.session_id AND session.status = 'active'
  WHERE queue.id = p_queue_id
  FOR UPDATE OF queue;
  IF NOT FOUND
     OR v_queue.restaurant_id <> v_assignment.restaurant_id
     OR (v_assignment.station_type = 'floor'
       AND v_assignment.floor_label <> v_queue.floor_label) THEN
    RAISE EXCEPTION 'EMERGENCY_ORDER_UNAVAILABLE';
  END IF;

  SELECT * INTO v_original
  FROM public.emergency_fulfillment_actions
  WHERE action_id = p_action_id
    AND queue_id = p_queue_id
    AND station_type = v_assignment.station_type
    AND action_kind = 'complete';
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_REVERT_ACTION_UNAVAILABLE'; END IF;

  SELECT action.action_id INTO v_latest_action_id
  FROM public.emergency_fulfillment_actions action
  WHERE action.queue_id = p_queue_id
    AND action.station_type = v_assignment.station_type
    AND action.action_kind = 'complete'
    AND NOT EXISTS (
      SELECT 1 FROM public.emergency_fulfillment_actions reversal
      WHERE reversal.original_action_id = action.action_id
        AND reversal.action_kind = 'revert'
    )
  ORDER BY action.created_at DESC, action.action_id DESC
  LIMIT 1;
  IF v_latest_action_id IS DISTINCT FROM p_action_id THEN
    RAISE EXCEPTION 'EMERGENCY_REVERT_NOT_LATEST_ACTION';
  END IF;

  INSERT INTO public.emergency_fulfillment_actions (
    action_id, session_id, restaurant_id, queue_id, order_id,
    station_type, floor_label, action_kind, stage,
    original_action_id, actor_user_id
  ) VALUES (
    p_revert_id, v_original.session_id, v_original.restaurant_id,
    v_original.queue_id, v_original.order_id, v_original.station_type,
    v_original.floor_label, 'revert', v_original.stage,
    p_action_id, v_user.id
  ) ON CONFLICT (action_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT * INTO v_existing
    FROM public.emergency_fulfillment_actions
    WHERE action_id = p_revert_id;
    IF v_existing.original_action_id IS DISTINCT FROM p_action_id
       OR v_existing.action_kind <> 'revert' THEN
      RAISE EXCEPTION 'EMERGENCY_ACTION_ID_CONFLICT';
    END IF;
    RETURN jsonb_build_object(
      'action_id', p_revert_id,
      'reverted_action_id', p_action_id,
      'deduplicated', true,
      'changed_quantity', 0
    );
  END IF;

  FOR v_event IN
    SELECT event.order_item_id, event.stage, SUM(event.delta)::integer AS delta
    FROM public.emergency_fulfillment_events event
    WHERE event.action_id = p_action_id AND event.delta > 0
    GROUP BY event.order_item_id, event.stage
    ORDER BY event.order_item_id,
      CASE event.stage
        WHEN 'tray_dispatched' THEN 1
        WHEN 'tray_received' THEN 2
        ELSE 1
      END
  LOOP
    SELECT * INTO v_item
    FROM public.emergency_fulfillment_items
    WHERE order_item_id = v_event.order_item_id
      AND queue_id = p_queue_id
      AND is_cancelled = false
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_REVERT_ITEM_UNAVAILABLE'; END IF;

    IF v_event.stage = 'kitchen_done' THEN
      IF v_item.kitchen_done_quantity - v_event.delta
         < v_item.tray_received_quantity THEN
        RAISE EXCEPTION 'EMERGENCY_REVERT_DOWNSTREAM_PROGRESS';
      END IF;
      UPDATE public.emergency_fulfillment_items
      SET kitchen_done_quantity = kitchen_done_quantity - v_event.delta,
          updated_at = now()
      WHERE id = v_item.id;
    ELSIF v_event.stage = 'tray_dispatched' THEN
      IF v_item.tray_dispatched_quantity - v_event.delta
         < v_item.floor_served_quantity THEN
        RAISE EXCEPTION 'EMERGENCY_REVERT_DOWNSTREAM_PROGRESS';
      END IF;
      UPDATE public.emergency_fulfillment_items
      SET tray_dispatched_quantity = tray_dispatched_quantity - v_event.delta,
          updated_at = now()
      WHERE id = v_item.id;
    ELSIF v_event.stage = 'tray_received' THEN
      IF v_item.tray_received_quantity - v_event.delta
         < v_item.tray_dispatched_quantity THEN
        RAISE EXCEPTION 'EMERGENCY_REVERT_DOWNSTREAM_PROGRESS';
      END IF;
      UPDATE public.emergency_fulfillment_items
      SET tray_received_quantity = tray_received_quantity - v_event.delta,
          updated_at = now()
      WHERE id = v_item.id;
    ELSIF v_event.stage = 'floor_served' THEN
      UPDATE public.emergency_fulfillment_items
      SET floor_served_quantity = floor_served_quantity - v_event.delta,
          updated_at = now()
      WHERE id = v_item.id;
    ELSE
      RAISE EXCEPTION 'EMERGENCY_REVERT_STAGE_INVALID';
    END IF;

    INSERT INTO public.emergency_fulfillment_events (
      event_id, session_id, restaurant_id, order_id, order_item_id,
      stage, delta, actor_user_id, action_id, details
    ) VALUES (
      gen_random_uuid(), v_item.session_id, v_item.restaurant_id,
      v_item.order_id, v_item.order_item_id, v_event.stage,
      -v_event.delta, v_user.id, p_revert_id,
      jsonb_build_object('reverts_action_id', p_action_id)
    );
    v_changed := v_changed + v_event.delta;
  END LOOP;

  IF v_changed <= 0 THEN RAISE EXCEPTION 'EMERGENCY_REVERT_EMPTY'; END IF;

  RETURN jsonb_build_object(
    'action_id', p_revert_id,
    'reverted_action_id', p_action_id,
    'deduplicated', false,
    'changed_quantity', v_changed
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_emergency_station_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_orders jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;

  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('assigned', false, 'active', false,
      'restaurant_id', v_user.restaurant_id, 'orders', '[]'::jsonb);
  END IF;

  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = v_assignment.restaurant_id AND status = 'active';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('assigned', true, 'active', false,
      'restaurant_id', v_assignment.restaurant_id,
      'station_type', v_assignment.station_type,
      'floor_label', v_assignment.floor_label, 'orders', '[]'::jsonb);
  END IF;

  SELECT COALESCE(jsonb_agg(order_payload ORDER BY queue_no), '[]'::jsonb)
  INTO v_orders
  FROM (
    SELECT queue.queue_no,
      jsonb_build_object(
        'queue_id', queue.id,
        'order_id', queue.order_id,
        'queue_no', queue.queue_no,
        'table_number', queue.table_number,
        'floor_label', queue.floor_label,
        'created_at', queue.created_at,
        'last_action_id', recent.action_id,
        'last_action_at', recent.created_at,
        'items', COALESCE((
          SELECT jsonb_agg(jsonb_build_object(
            'id', fulfillment.id,
            'order_item_id', fulfillment.order_item_id,
            'name_ko', COALESCE(NULLIF(item.label, ''), NULLIF(item.display_name, ''), menu.name, '메뉴'),
            'name_vi', COALESCE(menu.name_vi, 'Món'),
            'name_en', COALESCE(menu.name_en, 'Item'),
            'ordered_quantity', fulfillment.ordered_quantity,
            'kitchen_done_quantity', fulfillment.kitchen_done_quantity,
            'tray_received_quantity', fulfillment.tray_received_quantity,
            'tray_dispatched_quantity', fulfillment.tray_dispatched_quantity,
            'floor_served_quantity', fulfillment.floor_served_quantity,
            'needs_review', fulfillment.needs_review
          ) ORDER BY item.created_at, item.id)
          FROM public.emergency_fulfillment_items fulfillment
          JOIN public.order_items item ON item.id = fulfillment.order_item_id
          LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
          WHERE fulfillment.queue_id = queue.id
            AND fulfillment.is_cancelled = false
        ), '[]'::jsonb)
      ) AS order_payload
    FROM public.emergency_order_queue queue
    LEFT JOIN LATERAL (
      SELECT action.action_id, action.created_at
      FROM public.emergency_fulfillment_actions action
      WHERE action.queue_id = queue.id
        AND action.station_type = v_assignment.station_type
        AND action.action_kind = 'complete'
        AND NOT EXISTS (
          SELECT 1 FROM public.emergency_fulfillment_actions reversal
          WHERE reversal.original_action_id = action.action_id
            AND reversal.action_kind = 'revert'
        )
      ORDER BY action.created_at DESC, action.action_id DESC
      LIMIT 1
    ) recent ON true
    WHERE queue.session_id = v_session.id
      AND (v_assignment.station_type <> 'floor'
        OR queue.floor_label = v_assignment.floor_label)
  ) rows;

  RETURN jsonb_build_object(
    'assigned', true, 'active', true,
    'session_id', v_session.id,
    'restaurant_id', v_assignment.restaurant_id,
    'station_type', v_assignment.station_type,
    'floor_label', v_assignment.floor_label,
    'activated_at', v_session.activated_at,
    'orders', v_orders
  );
END;
$$;

REVOKE ALL ON FUNCTION public.emergency_complete_order_stage(uuid,uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.emergency_revert_order_action(uuid,uuid,uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emergency_complete_order_stage(uuid,uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.emergency_revert_order_action(uuid,uuid,uuid)
  TO authenticated;
