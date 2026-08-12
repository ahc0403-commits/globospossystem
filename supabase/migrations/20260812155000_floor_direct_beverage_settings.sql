BEGIN;

-- Keep the original mode switch contract, while treating direct beverages as
-- part of the same drainable paperless session.
CREATE OR REPLACE FUNCTION public.super_admin_set_fulfillment_mode(
  p_store_id uuid,
  p_mode text,
  p_reason text,
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_previous text;
  v_existing public.fulfillment_mode_changes%ROWTYPE;
  v_session public.emergency_fulfillment_sessions%ROWTYPE;
  v_unresolved integer := 0;
BEGIN
  SELECT * INTO v_actor FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true;
  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_SUPER_ADMIN_REQUIRED';
  END IF;
  IF p_store_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.restaurants
    WHERE id = p_store_id AND is_active = true
  ) THEN RAISE EXCEPTION 'FULFILLMENT_MODE_STORE_UNAVAILABLE'; END IF;
  IF p_mode NOT IN ('pos_print', 'paperless') THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_INVALID';
  END IF;
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_REQUEST_ID_REQUIRED';
  END IF;
  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_REASON_REQUIRED';
  END IF;

  SELECT * INTO v_existing FROM public.fulfillment_mode_changes
  WHERE request_id = p_request_id;
  IF FOUND THEN
    IF v_existing.restaurant_id <> p_store_id
       OR v_existing.next_mode <> p_mode THEN
      RAISE EXCEPTION 'FULFILLMENT_MODE_REQUEST_CONFLICT';
    END IF;
    RETURN jsonb_build_object(
      'mode', v_existing.next_mode,
      'previous_mode', v_existing.previous_mode,
      'deduplicated', true
    );
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended('fulfillment-mode:' || p_store_id::text, 0)
  );
  v_previous := public.get_store_fulfillment_mode(p_store_id);
  INSERT INTO public.restaurant_settings(
    restaurant_id, fulfillment_mode, updated_at
  ) VALUES (p_store_id, p_mode, now())
  ON CONFLICT (restaurant_id) DO UPDATE SET
    fulfillment_mode = EXCLUDED.fulfillment_mode,
    updated_at = now();

  SELECT * INTO v_session
  FROM public.emergency_fulfillment_sessions
  WHERE restaurant_id = p_store_id AND status = 'active'
  FOR UPDATE;
  IF p_mode = 'paperless' AND NOT FOUND THEN
    INSERT INTO public.emergency_fulfillment_sessions(
      restaurant_id, reason, activated_by
    ) VALUES (p_store_id, 'paperless: ' || btrim(p_reason), v_actor.id)
    RETURNING * INTO v_session;
  ELSIF p_mode = 'pos_print' AND FOUND THEN
    SELECT COALESCE(sum(progress.unserved), 0)::integer INTO v_unresolved
    FROM (
      SELECT item.ordered_quantity - item.floor_served_quantity AS unserved
      FROM public.emergency_fulfillment_items item
      WHERE item.session_id = v_session.id AND item.is_cancelled = false
      UNION ALL
      SELECT item.ordered_quantity - item.floor_served_quantity
      FROM public.emergency_floor_direct_items item
      WHERE item.session_id = v_session.id AND item.is_cancelled = false
    ) progress;
    IF v_unresolved = 0 THEN
      UPDATE public.emergency_fulfillment_sessions
      SET status = 'closed', closed_by = v_actor.id, closed_at = now(),
          close_reason = 'paperless mode drained',
          close_resolution = 'digital_completed', force_closed = false,
          updated_at = now()
      WHERE id = v_session.id;
    END IF;
  END IF;

  INSERT INTO public.fulfillment_mode_changes(
    request_id, restaurant_id, previous_mode, next_mode,
    reason, actor_user_id
  ) VALUES (
    p_request_id, p_store_id, v_previous, p_mode, btrim(p_reason), v_actor.id
  );
  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'set_fulfillment_mode', 'restaurants', p_store_id,
    jsonb_build_object(
      'previous_mode', v_previous, 'next_mode', p_mode,
      'reason', btrim(p_reason), 'request_id', p_request_id,
      'unresolved_quantity', v_unresolved
    )
  );
  RETURN jsonb_build_object(
    'mode', p_mode, 'previous_mode', v_previous, 'deduplicated', false,
    'draining', p_mode = 'pos_print' AND v_unresolved > 0,
    'unresolved_quantity', v_unresolved, 'session_id', v_session.id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.super_admin_get_fulfillment_store_statuses()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_SUPER_ADMIN_REQUIRED';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'restaurant_id', restaurant.id,
      'restaurant_name', restaurant.name,
      'mode', COALESCE(settings.fulfillment_mode, 'pos_print'),
      'floor_direct_beverages_enabled',
        COALESCE(settings.floor_direct_beverages_enabled, false),
      'session_id', session.id,
      'unresolved_quantity', COALESCE(summary.unresolved_quantity, 0),
      'order_count', COALESCE(summary.order_count, 0),
      'draining', COALESCE(settings.fulfillment_mode, 'pos_print') = 'pos_print'
        AND COALESCE(summary.unresolved_quantity, 0) > 0,
      'kds_ready', COALESCE(stations.kitchen_count, 0) > 0
        AND COALESCE(stations.tray_count, 0) > 0
        AND COALESCE(stations.floor_count, 0) > 0,
      'reason', change.reason,
      'changed_at', change.created_at
    ) ORDER BY restaurant.name)
    FROM public.restaurants restaurant
    LEFT JOIN public.restaurant_settings settings
      ON settings.restaurant_id = restaurant.id
    LEFT JOIN public.emergency_fulfillment_sessions session
      ON session.restaurant_id = restaurant.id AND session.status = 'active'
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(sum(progress.unserved), 0)::integer AS unresolved_quantity,
        count(DISTINCT progress.order_id)::integer AS order_count
      FROM (
        SELECT item.order_id,
          item.ordered_quantity - item.floor_served_quantity AS unserved
        FROM public.emergency_fulfillment_items item
        WHERE item.session_id = session.id AND item.is_cancelled = false
        UNION ALL
        SELECT item.order_id,
          item.ordered_quantity - item.floor_served_quantity
        FROM public.emergency_floor_direct_items item
        WHERE item.session_id = session.id AND item.is_cancelled = false
      ) progress
    ) summary ON true
    LEFT JOIN LATERAL (
      SELECT
        count(*) FILTER (WHERE station_type = 'kitchen')::integer kitchen_count,
        count(*) FILTER (WHERE station_type = 'tray')::integer tray_count,
        count(*) FILTER (WHERE station_type = 'floor')::integer floor_count
      FROM public.emergency_station_assignments assignment
      WHERE assignment.restaurant_id = restaurant.id
        AND assignment.is_active = true
    ) stations ON true
    LEFT JOIN LATERAL (
      SELECT mode_change.reason, mode_change.created_at
      FROM public.fulfillment_mode_changes mode_change
      WHERE mode_change.restaurant_id = restaurant.id
      ORDER BY mode_change.created_at DESC LIMIT 1
    ) change ON true
    WHERE restaurant.is_active = true
  ), '[]'::jsonb);
END;
$$;

COMMIT;
