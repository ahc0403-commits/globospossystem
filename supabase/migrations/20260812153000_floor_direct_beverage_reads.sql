BEGIN;

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
  SELECT * INTO v_user FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMERGENCY_USER_REQUIRED'; END IF;
  SELECT * INTO v_assignment
  FROM public.emergency_station_assignments
  WHERE user_id = v_user.id AND restaurant_id = v_user.restaurant_id
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

CREATE OR REPLACE FUNCTION public.get_emergency_order_summaries(
  p_order_ids uuid[]
) RETURNS TABLE (
  order_id uuid,
  emergency_active boolean,
  unserved_quantity integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
BEGIN
  IF p_order_ids IS NULL OR cardinality(p_order_ids) = 0 THEN RETURN; END IF;
  RETURN QUERY
  WITH progress AS (
    SELECT item.order_id, item.restaurant_id, item.session_id,
      item.ordered_quantity, item.floor_served_quantity, item.is_cancelled
    FROM public.emergency_fulfillment_items item
    UNION ALL
    SELECT item.order_id, item.restaurant_id, item.session_id,
      item.ordered_quantity, item.floor_served_quantity, item.is_cancelled
    FROM public.emergency_floor_direct_items item
  )
  SELECT progress.order_id, true,
    COALESCE(sum(
      progress.ordered_quantity - progress.floor_served_quantity
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
  floor_served_quantity integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
BEGIN
  IF p_order_ids IS NULL OR cardinality(p_order_ids) = 0 THEN RETURN; END IF;
  RETURN QUERY
  SELECT
    progress.order_id,
    progress.order_item_id,
    progress.fulfillment_item_id,
    progress.line_key,
    progress.source_kind,
    progress.fulfillment_route,
    progress.name_ko,
    progress.name_vi,
    progress.name_en,
    progress.ordered_quantity,
    progress.floor_served_quantity
  FROM (
    SELECT item.order_id, item.order_item_id, item.id,
      'base'::text, 'order_item'::text, 'kitchen_tray_floor'::text,
      COALESCE(NULLIF(order_item.label, ''), NULLIF(order_item.display_name, ''),
        menu.name_ko, menu.name, '메뉴')::text,
      COALESCE(NULLIF(menu.name_vi, ''), NULLIF(order_item.display_name, ''),
        menu.name, 'Món')::text,
      COALESCE(NULLIF(menu.name_en, ''), NULLIF(order_item.display_name, ''),
        menu.name, 'Item')::text,
      item.ordered_quantity, item.floor_served_quantity,
      item.restaurant_id, item.session_id, item.is_cancelled
    FROM public.emergency_fulfillment_items item
    JOIN public.order_items order_item ON order_item.id = item.order_item_id
    LEFT JOIN public.menu_items menu ON menu.id = order_item.menu_item_id

    UNION ALL

    SELECT item.order_id, item.order_item_id, item.id,
      item.line_key, item.source_kind, 'floor_direct'::text,
      item.name_ko, item.name_vi, item.name_en,
      item.ordered_quantity, item.floor_served_quantity,
      item.restaurant_id, item.session_id, item.is_cancelled
    FROM public.emergency_floor_direct_items item
  ) progress(
    order_id, order_item_id, fulfillment_item_id,
    line_key, source_kind, fulfillment_route,
    name_ko, name_vi, name_en,
    ordered_quantity, floor_served_quantity,
    restaurant_id, session_id, is_cancelled
  )
  JOIN public.emergency_fulfillment_sessions session
    ON session.id = progress.session_id
  WHERE progress.order_id = ANY(p_order_ids)
    AND progress.is_cancelled = false
    AND session.status = 'active'
    AND (public.is_super_admin() OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores((SELECT auth.uid())) scope(store_id)
      WHERE scope.store_id = progress.restaurant_id
    ));
END;
$$;

REVOKE ALL ON FUNCTION public.get_emergency_order_item_progress(uuid[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_emergency_order_item_progress(uuid[])
  TO authenticated;

CREATE OR REPLACE FUNCTION public.close_drained_paperless_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
BEGIN
  IF public.get_store_fulfillment_mode(NEW.restaurant_id) <> 'pos_print' THEN
    RETURN NEW;
  END IF;
  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE id = NEW.session_id AND status = 'active'
  FOR UPDATE;
  IF NOT FOUND OR EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items item
    WHERE item.session_id = v_session.id
      AND item.is_cancelled = false
      AND item.floor_served_quantity < item.ordered_quantity
  ) OR EXISTS (
    SELECT 1 FROM public.emergency_floor_direct_items item
    WHERE item.session_id = v_session.id
      AND item.is_cancelled = false
      AND item.floor_served_quantity < item.ordered_quantity
  ) THEN RETURN NEW; END IF;
  UPDATE public.emergency_fulfillment_sessions
  SET status = 'closed',
      closed_by = COALESCE((
        SELECT user_row.id FROM public.users user_row
        WHERE user_row.auth_id = auth.uid() LIMIT 1
      ), v_session.activated_by),
      closed_at = now(),
      close_reason = 'paperless mode drained',
      close_resolution = 'digital_completed',
      force_closed = false,
      updated_at = now()
  WHERE id = v_session.id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS close_drained_floor_direct_session_trigger
  ON public.emergency_floor_direct_items;
CREATE TRIGGER close_drained_floor_direct_session_trigger
AFTER UPDATE OF floor_served_quantity, is_cancelled
ON public.emergency_floor_direct_items
FOR EACH ROW EXECUTE FUNCTION public.close_drained_paperless_session();

COMMIT;
