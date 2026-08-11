BEGIN;

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

DROP FUNCTION IF EXISTS public.emergency_revert_order_action(uuid,uuid,uuid);
DROP FUNCTION IF EXISTS public.emergency_complete_order_stage(uuid,uuid);
ALTER TABLE public.emergency_fulfillment_events
  DROP COLUMN IF EXISTS action_id;
DROP TABLE IF EXISTS public.emergency_fulfillment_actions;

COMMIT;
