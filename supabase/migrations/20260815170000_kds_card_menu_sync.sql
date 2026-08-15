BEGIN;

-- production-gate: self-verifying

-- Keep the existing station snapshot contract and add the immutable combo
-- component snapshot needed by the shared kitchen/tray/floor presentation.
CREATE OR REPLACE FUNCTION public.get_emergency_station_snapshot()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_orders jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_user
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;

  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'assigned', false, 'active', false,
      'restaurant_id', v_user.restaurant_id, 'orders', '[]'::jsonb
    );
  END IF;

  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = v_assignment.restaurant_id AND status = 'active';
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'assigned', true, 'active', false,
      'restaurant_id', v_assignment.restaurant_id,
      'station_type', v_assignment.station_type,
      'floor_label', v_assignment.floor_label,
      'orders', '[]'::jsonb
    );
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
          SELECT jsonb_agg(item_payload ORDER BY created_at, order_item_id, line_key)
          FROM (
            SELECT
              fulfillment.created_at,
              fulfillment.order_item_id,
              'base'::text AS line_key,
              jsonb_build_object(
                'id', fulfillment.id,
                'order_item_id', fulfillment.order_item_id,
                'line_key', 'base',
                'source_kind', 'order_item',
                'fulfillment_route', 'kitchen_tray_floor',
                'name_ko', COALESCE(NULLIF(item.label, ''),
                  NULLIF(item.display_name, ''), menu.name_ko, menu.name, '메뉴'),
                'name_vi', COALESCE(NULLIF(menu.name_vi, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Món'),
                'name_en', COALESCE(NULLIF(menu.name_en, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Item'),
                'combo_components', COALESCE(item.combo_components, '[]'::jsonb),
                'ordered_quantity', fulfillment.ordered_quantity,
                'kitchen_done_quantity', fulfillment.kitchen_done_quantity,
                'tray_received_quantity', fulfillment.tray_received_quantity,
                'tray_dispatched_quantity', fulfillment.tray_dispatched_quantity,
                'floor_served_quantity', fulfillment.floor_served_quantity,
                'needs_review', fulfillment.needs_review
              ) AS item_payload
            FROM public.emergency_fulfillment_items fulfillment
            JOIN public.order_items item ON item.id = fulfillment.order_item_id
            LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
            WHERE fulfillment.queue_id = queue.id
              AND fulfillment.is_cancelled = false

            UNION ALL

            SELECT
              direct.created_at,
              direct.order_item_id,
              direct.line_key,
              jsonb_build_object(
                'id', direct.id,
                'order_item_id', direct.order_item_id,
                'line_key', direct.line_key,
                'source_kind', direct.source_kind,
                'fulfillment_route', 'floor_direct',
                'name_ko', direct.name_ko,
                'name_vi', direct.name_vi,
                'name_en', direct.name_en,
                'combo_components', '[]'::jsonb,
                'ordered_quantity', direct.ordered_quantity,
                'kitchen_done_quantity', 0,
                'tray_received_quantity', 0,
                'tray_dispatched_quantity', 0,
                'floor_served_quantity', direct.floor_served_quantity,
                'needs_review', direct.needs_review
              ) AS item_payload
            FROM public.emergency_floor_direct_items direct
            WHERE direct.queue_id = queue.id
              AND direct.is_cancelled = false
          ) station_items
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
          SELECT 1
          FROM public.emergency_fulfillment_actions reversal
          WHERE reversal.original_action_id = action.action_id
            AND reversal.action_kind = 'revert'
        )
      ORDER BY action.created_at DESC, action.action_id DESC
      LIMIT 1
    ) recent ON true
    WHERE queue.session_id = v_session.id
      AND (
        v_assignment.station_type <> 'floor'
        OR queue.floor_label = v_assignment.floor_label
      )
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

-- Durable today history is derived from the append-only actions/events and
-- the current quantity ledgers, so item-by-item completion and whole-order
-- completion share one authoritative result without a duplicate history table.
CREATE OR REPLACE FUNCTION public.get_emergency_station_today_completed()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_assignment public.emergency_station_assignments%ROWTYPE;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_orders jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_user
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;

  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id
    AND restaurant_id = v_user.restaurant_id
    AND is_active = true;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;

  v_day_start := (
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh'
  );
  v_day_end := v_day_start + interval '1 day';

  SELECT COALESCE(
    jsonb_agg(order_payload ORDER BY completed_at DESC, queue_no DESC),
    '[]'::jsonb
  )
  INTO v_orders
  FROM (
    SELECT queue.queue_no, completion.completed_at,
      jsonb_build_object(
        'queue_id', queue.id,
        'order_id', queue.order_id,
        'queue_no', queue.queue_no,
        'table_number', queue.table_number,
        'floor_label', queue.floor_label,
        'created_at', queue.created_at,
        'last_action_id', recent.action_id,
        'last_action_at', completion.completed_at,
        'items', COALESCE((
          SELECT jsonb_agg(item_payload ORDER BY created_at, order_item_id, line_key)
          FROM (
            SELECT fulfillment.created_at, fulfillment.order_item_id,
              'base'::text AS line_key,
              jsonb_build_object(
                'id', fulfillment.id,
                'order_item_id', fulfillment.order_item_id,
                'line_key', 'base',
                'source_kind', 'order_item',
                'fulfillment_route', 'kitchen_tray_floor',
                'name_ko', COALESCE(NULLIF(item.label, ''),
                  NULLIF(item.display_name, ''), menu.name_ko, menu.name, '메뉴'),
                'name_vi', COALESCE(NULLIF(menu.name_vi, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Món'),
                'name_en', COALESCE(NULLIF(menu.name_en, ''),
                  NULLIF(item.display_name, ''), menu.name, 'Item'),
                'combo_components', COALESCE(item.combo_components, '[]'::jsonb),
                'ordered_quantity', fulfillment.ordered_quantity,
                'kitchen_done_quantity', fulfillment.kitchen_done_quantity,
                'tray_received_quantity', fulfillment.tray_received_quantity,
                'tray_dispatched_quantity', fulfillment.tray_dispatched_quantity,
                'floor_served_quantity', fulfillment.floor_served_quantity,
                'needs_review', fulfillment.needs_review
              ) AS item_payload
            FROM public.emergency_fulfillment_items fulfillment
            JOIN public.order_items item ON item.id = fulfillment.order_item_id
            LEFT JOIN public.menu_items menu ON menu.id = item.menu_item_id
            WHERE fulfillment.queue_id = queue.id
              AND fulfillment.is_cancelled = false

            UNION ALL

            SELECT direct.created_at, direct.order_item_id, direct.line_key,
              jsonb_build_object(
                'id', direct.id,
                'order_item_id', direct.order_item_id,
                'line_key', direct.line_key,
                'source_kind', direct.source_kind,
                'fulfillment_route', 'floor_direct',
                'name_ko', direct.name_ko,
                'name_vi', direct.name_vi,
                'name_en', direct.name_en,
                'combo_components', '[]'::jsonb,
                'ordered_quantity', direct.ordered_quantity,
                'kitchen_done_quantity', 0,
                'tray_received_quantity', 0,
                'tray_dispatched_quantity', 0,
                'floor_served_quantity', direct.floor_served_quantity,
                'needs_review', direct.needs_review
              ) AS item_payload
            FROM public.emergency_floor_direct_items direct
            WHERE direct.queue_id = queue.id
              AND direct.is_cancelled = false
          ) completed_items
        ), '[]'::jsonb)
      ) AS order_payload
    FROM public.emergency_order_queue queue
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = queue.session_id
    JOIN LATERAL (
      SELECT max(event.created_at) AS completed_at
      FROM public.emergency_fulfillment_events event
      WHERE event.session_id = queue.session_id
        AND event.order_id = queue.order_id
        AND event.created_at >= v_day_start
        AND event.created_at < v_day_end
        AND event.delta > 0
        AND event.stage = CASE v_assignment.station_type
          WHEN 'kitchen' THEN 'kitchen_done'
          WHEN 'tray' THEN 'tray_dispatched'
          ELSE 'floor_served'
        END
    ) completion ON completion.completed_at IS NOT NULL
    LEFT JOIN LATERAL (
      SELECT action.action_id
      FROM public.emergency_fulfillment_actions action
      WHERE action.queue_id = queue.id
        AND action.station_type = v_assignment.station_type
        AND action.action_kind = 'complete'
        AND NOT EXISTS (
          SELECT 1
          FROM public.emergency_fulfillment_actions reversal
          WHERE reversal.original_action_id = action.action_id
            AND reversal.action_kind = 'revert'
        )
      ORDER BY action.created_at DESC, action.action_id DESC
      LIMIT 1
    ) recent ON true
    WHERE queue.restaurant_id = v_assignment.restaurant_id
      AND (
        v_assignment.station_type <> 'floor'
        OR queue.floor_label = v_assignment.floor_label
      )
      AND CASE v_assignment.station_type
        WHEN 'kitchen' THEN
          EXISTS (
            SELECT 1 FROM public.emergency_fulfillment_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.emergency_fulfillment_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
              AND item.kitchen_done_quantity < item.ordered_quantity
          )
        WHEN 'tray' THEN
          EXISTS (
            SELECT 1 FROM public.emergency_fulfillment_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.emergency_fulfillment_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
              AND (
                item.tray_received_quantity < item.ordered_quantity
                OR item.tray_dispatched_quantity < item.ordered_quantity
              )
          )
        ELSE
          (
            EXISTS (
              SELECT 1 FROM public.emergency_fulfillment_items item
              WHERE item.queue_id = queue.id AND item.is_cancelled = false
            )
            OR EXISTS (
              SELECT 1 FROM public.emergency_floor_direct_items item
              WHERE item.queue_id = queue.id AND item.is_cancelled = false
            )
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.emergency_fulfillment_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
              AND item.floor_served_quantity < item.ordered_quantity
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.emergency_floor_direct_items item
            WHERE item.queue_id = queue.id AND item.is_cancelled = false
              AND item.floor_served_quantity < item.ordered_quantity
          )
      END
  ) completed_rows;

  RETURN v_orders;
END;
$$;

REVOKE ALL ON FUNCTION public.get_emergency_station_today_completed()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_today_completed()
  TO authenticated;

DO $$
DECLARE
  v_snapshot_definition text;
  v_history_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.get_emergency_station_snapshot()'::regprocedure
  )
  INTO v_snapshot_definition;

  IF v_snapshot_definition NOT LIKE '%''combo_components''%' THEN
    RAISE EXCEPTION 'KDS_COMBO_SNAPSHOT_VERIFICATION_FAILED';
  END IF;

  SELECT pg_catalog.pg_get_functiondef(
    'public.get_emergency_station_today_completed()'::regprocedure
  )
  INTO v_history_definition;

  IF v_history_definition NOT LIKE '%Asia/Ho_Chi_Minh%'
     OR v_history_definition NOT LIKE '%emergency_fulfillment_events%'
     OR v_history_definition NOT LIKE '%combo_components%' THEN
    RAISE EXCEPTION 'KDS_TODAY_HISTORY_VERIFICATION_FAILED';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_emergency_station_today_completed()',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'anon',
    'public.get_emergency_station_today_completed()',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'KDS_TODAY_HISTORY_GRANT_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
