BEGIN;

CREATE OR REPLACE FUNCTION public.emergency_record_floor_direct_progress(
  p_floor_direct_item_id uuid,
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
  v_item public.emergency_floor_direct_items%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_next integer;
BEGIN
  IF p_event_id IS NULL OR p_delta NOT IN (-1, 1) THEN
    RAISE EXCEPTION 'EMERGENCY_PROGRESS_INPUT_INVALID';
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
  SELECT * INTO v_item
  FROM public.emergency_floor_direct_items
  WHERE id = p_floor_direct_item_id
  FOR UPDATE;
  IF NOT FOUND OR v_item.restaurant_id <> v_assignment.restaurant_id
     OR v_item.is_cancelled THEN
    RAISE EXCEPTION 'EMERGENCY_ITEM_UNAVAILABLE';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_sessions
    WHERE id = v_item.session_id AND status = 'active'
  ) THEN RAISE EXCEPTION 'EMERGENCY_SESSION_NOT_ACTIVE'; END IF;
  -- Check idempotency after the item lock so concurrent retries with the same
  -- event ID cannot both pass the existence check and race the unique index.
  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_events
    WHERE event_id = p_event_id
  ) THEN
    RETURN jsonb_build_object('event_id', p_event_id, 'deduplicated', true);
  END IF;
  SELECT * INTO v_queue
  FROM public.emergency_order_queue WHERE id = v_item.queue_id;
  IF v_assignment.station_type <> 'floor'
     OR v_assignment.floor_label <> v_queue.floor_label THEN
    RAISE EXCEPTION 'EMERGENCY_STAGE_FORBIDDEN';
  END IF;

  v_next := v_item.floor_served_quantity + p_delta;
  IF v_next < 0 OR v_next > v_item.ordered_quantity THEN
    RAISE EXCEPTION 'EMERGENCY_QUANTITY_CHAIN_VIOLATION';
  END IF;
  UPDATE public.emergency_floor_direct_items
  SET floor_served_quantity = v_next, updated_at = now()
  WHERE id = v_item.id;
  INSERT INTO public.emergency_fulfillment_events (
    event_id, session_id, restaurant_id, order_id, order_item_id,
    floor_direct_item_id, stage, delta, actor_user_id, details
  ) VALUES (
    p_event_id, v_item.session_id, v_item.restaurant_id, v_item.order_id,
    v_item.order_item_id, v_item.id, 'floor_served', p_delta, v_user.id,
    jsonb_build_object(
      'fulfillment_route', 'floor_direct',
      'line_key', v_item.line_key
    )
  );
  RETURN jsonb_build_object(
    'event_id', p_event_id,
    'deduplicated', false,
    'floor_served_quantity', v_next
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.emergency_complete_route_order_stage(
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
  v_direct public.emergency_floor_direct_items%ROWTYPE;
  v_standard_result jsonb := '{}'::jsonb;
  v_standard_changed integer := 0;
  v_direct_changed integer := 0;
  v_delta integer;
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
  IF NOT FOUND OR v_queue.restaurant_id <> v_assignment.restaurant_id
     OR (v_assignment.station_type = 'floor'
       AND v_assignment.floor_label <> v_queue.floor_label) THEN
    RAISE EXCEPTION 'EMERGENCY_ORDER_UNAVAILABLE';
  END IF;

  SELECT * INTO v_existing
  FROM public.emergency_fulfillment_actions
  WHERE action_id = p_action_id;
  IF FOUND THEN
    IF v_existing.queue_id <> p_queue_id
       OR v_existing.station_type <> v_assignment.station_type
       OR v_existing.action_kind <> 'complete' THEN
      RAISE EXCEPTION 'EMERGENCY_ACTION_ID_CONFLICT';
    END IF;
    RETURN jsonb_build_object(
      'action_id', p_action_id, 'deduplicated', true, 'changed_quantity', 0
    );
  END IF;

  BEGIN
    v_standard_result := public.emergency_complete_order_stage(
      p_queue_id, p_action_id
    );
    v_standard_changed := COALESCE(
      (v_standard_result->>'changed_quantity')::integer, 0
    );
  EXCEPTION WHEN raise_exception THEN
    IF position('EMERGENCY_ORDER_STAGE_ALREADY_COMPLETE' IN SQLERRM) = 0 THEN
      RAISE;
    END IF;
  END;

  IF v_assignment.station_type = 'floor' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.emergency_fulfillment_actions
      WHERE action_id = p_action_id
    ) THEN
      INSERT INTO public.emergency_fulfillment_actions (
        action_id, session_id, restaurant_id, queue_id, order_id,
        station_type, floor_label, action_kind, stage, actor_user_id
      ) VALUES (
        p_action_id, v_queue.session_id, v_queue.restaurant_id,
        v_queue.id, v_queue.order_id, 'floor', v_assignment.floor_label,
        'complete', 'floor_served', v_user.id
      ) ON CONFLICT (action_id) DO NOTHING;
      GET DIAGNOSTICS v_inserted = ROW_COUNT;
      IF v_inserted = 0 THEN
        RAISE EXCEPTION 'EMERGENCY_ACTION_ID_CONFLICT';
      END IF;
    END IF;

    FOR v_direct IN
      SELECT *
      FROM public.emergency_floor_direct_items
      WHERE queue_id = p_queue_id AND is_cancelled = false
      ORDER BY id
      FOR UPDATE
    LOOP
      v_delta := v_direct.ordered_quantity - v_direct.floor_served_quantity;
      IF v_delta <= 0 THEN CONTINUE; END IF;
      UPDATE public.emergency_floor_direct_items
      SET floor_served_quantity = ordered_quantity, updated_at = now()
      WHERE id = v_direct.id;
      INSERT INTO public.emergency_fulfillment_events (
        event_id, session_id, restaurant_id, order_id, order_item_id,
        floor_direct_item_id, stage, delta, actor_user_id, details
      ) VALUES (
        gen_random_uuid(), v_direct.session_id, v_direct.restaurant_id,
        v_direct.order_id, v_direct.order_item_id, v_direct.id,
        'floor_served', v_delta, v_user.id,
        jsonb_build_object(
          'order_action', true,
          'order_action_id', p_action_id,
          'fulfillment_route', 'floor_direct',
          'line_key', v_direct.line_key
        )
      );
      v_direct_changed := v_direct_changed + v_delta;
    END LOOP;
  END IF;

  IF v_standard_changed + v_direct_changed <= 0 THEN
    RAISE EXCEPTION 'EMERGENCY_ORDER_STAGE_ALREADY_COMPLETE';
  END IF;
  RETURN jsonb_build_object(
    'action_id', p_action_id,
    'deduplicated', false,
    'changed_quantity', v_standard_changed + v_direct_changed,
    'standard_changed_quantity', v_standard_changed,
    'floor_direct_changed_quantity', v_direct_changed,
    'stage', CASE v_assignment.station_type
      WHEN 'kitchen' THEN 'kitchen_done'
      WHEN 'tray' THEN 'tray_handoff'
      ELSE 'floor_served'
    END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.emergency_revert_route_order_action(
  p_queue_id uuid,
  p_action_id uuid,
  p_revert_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_queue public.emergency_order_queue%ROWTYPE;
  v_original public.emergency_fulfillment_actions%ROWTYPE;
  v_existing public.emergency_fulfillment_actions%ROWTYPE;
  v_direct public.emergency_floor_direct_items%ROWTYPE;
  v_direct_event record;
  v_latest_action_id uuid;
  v_standard_changed integer := 0;
  v_direct_changed integer := 0;
  v_result jsonb;
  v_has_standard boolean := false;
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
  IF NOT FOUND OR v_queue.restaurant_id <> v_assignment.restaurant_id
     OR (v_assignment.station_type = 'floor'
       AND v_assignment.floor_label <> v_queue.floor_label) THEN
    RAISE EXCEPTION 'EMERGENCY_ORDER_UNAVAILABLE';
  END IF;

  SELECT * INTO v_existing
  FROM public.emergency_fulfillment_actions
  WHERE action_id = p_revert_id;
  IF FOUND THEN
    IF v_existing.original_action_id IS DISTINCT FROM p_action_id
       OR v_existing.queue_id <> p_queue_id
       OR v_existing.station_type <> v_assignment.station_type
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

  SELECT * INTO v_original
  FROM public.emergency_fulfillment_actions
  WHERE action_id = p_action_id
    AND queue_id = p_queue_id
    AND station_type = v_assignment.station_type
    AND action_kind = 'complete';
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_REVERT_ACTION_UNAVAILABLE'; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_events
    WHERE action_id = p_action_id AND delta > 0
  ) INTO v_has_standard;
  IF v_has_standard THEN
    v_result := public.emergency_revert_order_action(
      p_queue_id, p_action_id, p_revert_id
    );
    v_standard_changed := COALESCE((v_result->>'changed_quantity')::integer, 0);
  ELSE
    SELECT action.action_id INTO v_latest_action_id
    FROM public.emergency_fulfillment_actions action
    WHERE action.queue_id = p_queue_id
      AND action.station_type = v_assignment.station_type
      AND action.action_kind = 'complete'
      AND NOT EXISTS (
        SELECT 1
        FROM public.emergency_fulfillment_actions reversal
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
      RAISE EXCEPTION 'EMERGENCY_ACTION_ID_CONFLICT';
    END IF;
  END IF;

  IF v_assignment.station_type = 'floor' THEN
    FOR v_direct_event IN
      SELECT event.floor_direct_item_id,
             SUM(event.delta)::integer AS delta
      FROM public.emergency_fulfillment_events event
      WHERE event.details->>'order_action_id' = p_action_id::text
        AND event.stage = 'floor_served'
        AND event.delta > 0
        AND event.floor_direct_item_id IS NOT NULL
      GROUP BY event.floor_direct_item_id
    LOOP
      SELECT * INTO v_direct
      FROM public.emergency_floor_direct_items
      WHERE id = v_direct_event.floor_direct_item_id
        AND queue_id = p_queue_id
        AND is_cancelled = false
      FOR UPDATE;
      IF NOT FOUND OR v_direct.floor_served_quantity < v_direct_event.delta THEN
        RAISE EXCEPTION 'EMERGENCY_REVERT_ITEM_UNAVAILABLE';
      END IF;
      UPDATE public.emergency_floor_direct_items
      SET floor_served_quantity = floor_served_quantity - v_direct_event.delta,
          updated_at = now()
      WHERE id = v_direct.id;
      INSERT INTO public.emergency_fulfillment_events (
        event_id, session_id, restaurant_id, order_id, order_item_id,
        floor_direct_item_id, stage, delta, actor_user_id, details
      ) VALUES (
        gen_random_uuid(), v_direct.session_id, v_direct.restaurant_id,
        v_direct.order_id, v_direct.order_item_id, v_direct.id,
        'floor_served', -v_direct_event.delta, v_user.id,
        jsonb_build_object(
          'reverts_action_id', p_action_id,
          'revert_action_id', p_revert_id,
          'fulfillment_route', 'floor_direct',
          'line_key', v_direct.line_key
        )
      );
      v_direct_changed := v_direct_changed + v_direct_event.delta;
    END LOOP;
  END IF;

  IF v_standard_changed + v_direct_changed <= 0 THEN
    RAISE EXCEPTION 'EMERGENCY_REVERT_EMPTY';
  END IF;
  RETURN jsonb_build_object(
    'action_id', p_revert_id,
    'reverted_action_id', p_action_id,
    'deduplicated', false,
    'changed_quantity', v_standard_changed + v_direct_changed
  );
END;
$$;

REVOKE ALL ON FUNCTION public.emergency_record_floor_direct_progress(
  uuid, integer, uuid
) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.emergency_complete_route_order_stage(uuid, uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.emergency_revert_route_order_action(
  uuid, uuid, uuid
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emergency_record_floor_direct_progress(
  uuid, integer, uuid
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.emergency_complete_route_order_stage(uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.emergency_revert_route_order_action(
  uuid, uuid, uuid
) TO authenticated;

COMMIT;
