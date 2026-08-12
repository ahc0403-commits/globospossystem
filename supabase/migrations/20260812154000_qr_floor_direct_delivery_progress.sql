BEGIN;

CREATE OR REPLACE FUNCTION public.qr_get_active_order(p_token text)
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
  v_items jsonb := '[]'::jsonb;
BEGIN
  SELECT q.restaurant_id, q.table_id
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t
    ON t.id = q.table_id AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r
    ON r.id = q.restaurant_id AND r.is_active = true
  WHERE q.token = v_token AND q.is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'QR_TOKEN_INVALID'; END IF;

  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.restaurant_id = v_table.restaurant_id
    AND o.table_id = v_table.table_id
    AND o.status IN ('pending', 'confirmed', 'serving')
  ORDER BY o.created_at DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'active', false, 'order_code', '', 'status', '',
      'fulfillment_mode', 'pos_print', 'items', '[]'::jsonb
    );
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'name', COALESCE(NULLIF(oi.display_name, ''), NULLIF(oi.label, ''),
        NULLIF(mi.name, ''), 'Item'),
      'name_ko', COALESCE(NULLIF(mi.name_ko, ''), NULLIF(oi.display_name, ''),
        NULLIF(oi.label, ''), NULLIF(mi.name, ''), '메뉴'),
      'name_vi', COALESCE(NULLIF(mi.name_vi, ''), NULLIF(oi.display_name, ''),
        NULLIF(oi.label, ''), NULLIF(mi.name, ''), 'Món ăn'),
      'name_en', COALESCE(NULLIF(mi.name_en, ''), NULLIF(oi.display_name, ''),
        NULLIF(oi.label, ''), NULLIF(mi.name, ''), 'Item'),
      'quantity', oi.quantity,
      'status', oi.status,
      'served_quantity', CASE
        WHEN v_order.fulfillment_mode_snapshot = 'paperless'
          THEN LEAST(oi.quantity, GREATEST(COALESCE(base.floor_served, 0), 0))
        ELSE 0
      END,
      'fulfillment_parts', CASE
        WHEN v_order.fulfillment_mode_snapshot = 'paperless'
          THEN COALESCE(parts.payload, '[]'::jsonb)
        ELSE '[]'::jsonb
      END
    ) ORDER BY oi.created_at, oi.id
  ), '[]'::jsonb)
  INTO v_items
  FROM public.order_items oi
  LEFT JOIN public.menu_items mi
    ON mi.id = oi.menu_item_id AND mi.restaurant_id = oi.restaurant_id
  LEFT JOIN LATERAL (
    SELECT progress.floor_served AS floor_served
    FROM (
      SELECT standard.floor_served_quantity AS floor_served,
             session.activated_at, standard.created_at
      FROM public.emergency_fulfillment_items standard
      JOIN public.emergency_fulfillment_sessions session
        ON session.id = standard.session_id
      WHERE standard.order_item_id = oi.id
        AND standard.restaurant_id = v_table.restaurant_id
        AND standard.is_cancelled = false
      UNION ALL
      SELECT direct.floor_served_quantity,
             session.activated_at, direct.created_at
      FROM public.emergency_floor_direct_items direct
      JOIN public.emergency_fulfillment_sessions session
        ON session.id = direct.session_id
      WHERE direct.order_item_id = oi.id
        AND direct.restaurant_id = v_table.restaurant_id
        AND direct.line_key = 'base'
        AND direct.is_cancelled = false
    ) progress
    ORDER BY progress.activated_at DESC, progress.created_at DESC
    LIMIT 1
  ) base ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(progress.payload ORDER BY progress.sort_key, progress.line_key)
      AS payload
    FROM (
      SELECT standard.created_at AS sort_key, 'base'::text AS line_key,
        jsonb_build_object(
          'line_key', 'base',
          'source_kind', 'order_item',
          'fulfillment_route', 'kitchen_tray_floor',
          'name', COALESCE(NULLIF(oi.display_name, ''), NULLIF(oi.label, ''),
            NULLIF(mi.name, ''), 'Item'),
          'name_ko', COALESCE(NULLIF(mi.name_ko, ''), NULLIF(oi.display_name, ''),
            NULLIF(oi.label, ''), NULLIF(mi.name, ''), '메뉴'),
          'name_vi', COALESCE(NULLIF(mi.name_vi, ''), NULLIF(oi.display_name, ''),
            NULLIF(oi.label, ''), NULLIF(mi.name, ''), 'Món'),
          'name_en', COALESCE(NULLIF(mi.name_en, ''), NULLIF(oi.display_name, ''),
            NULLIF(oi.label, ''), NULLIF(mi.name, ''), 'Item'),
          'quantity', standard.ordered_quantity,
          'served_quantity', standard.floor_served_quantity
        ) AS payload
      FROM public.emergency_fulfillment_items standard
      JOIN public.emergency_fulfillment_sessions session
        ON session.id = standard.session_id AND session.status = 'active'
      WHERE standard.order_item_id = oi.id
        AND standard.restaurant_id = v_table.restaurant_id
        AND standard.is_cancelled = false

      UNION ALL

      SELECT direct.created_at, direct.line_key,
        jsonb_build_object(
          'line_key', direct.line_key,
          'source_kind', direct.source_kind,
          'fulfillment_route', 'floor_direct',
          'name', direct.name_en,
          'name_ko', direct.name_ko,
          'name_vi', direct.name_vi,
          'name_en', direct.name_en,
          'quantity', direct.ordered_quantity,
          'served_quantity', direct.floor_served_quantity
        )
      FROM public.emergency_floor_direct_items direct
      JOIN public.emergency_fulfillment_sessions session
        ON session.id = direct.session_id AND session.status = 'active'
      WHERE direct.order_item_id = oi.id
        AND direct.restaurant_id = v_table.restaurant_id
        AND direct.is_cancelled = false
    ) progress
  ) parts ON true
  WHERE oi.order_id = v_order.id
    AND oi.restaurant_id = v_table.restaurant_id
    AND oi.status <> 'cancelled'
    AND oi.item_type = 'menu_item'
    AND COALESCE(oi.is_service_item, false) = false;

  RETURN jsonb_build_object(
    'active', true,
    'order_code', substring(v_order.id::text from 1 for 8),
    'status', v_order.status,
    'fulfillment_mode', v_order.fulfillment_mode_snapshot,
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public.qr_get_active_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_get_active_order(text)
  TO anon, authenticated, service_role;

COMMIT;
