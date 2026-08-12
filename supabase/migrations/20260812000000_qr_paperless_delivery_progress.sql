BEGIN;

-- Keep the public QR lookup token-scoped while exposing the existing
-- paperless floor progress. Printed orders intentionally return the full
-- order only; the client hides operational status/progress for that mode.
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
    ON t.id = q.table_id
   AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r
    ON r.id = q.restaurant_id
   AND r.is_active = true
  WHERE q.token = v_token
    AND q.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR_TOKEN_INVALID';
  END IF;

  SELECT o.*
  INTO v_order
  FROM public.orders o
  WHERE o.restaurant_id = v_table.restaurant_id
    AND o.table_id = v_table.table_id
    AND o.status IN ('pending', 'confirmed', 'serving')
  ORDER BY o.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'active', false,
      'order_code', '',
      'status', '',
      'fulfillment_mode', 'pos_print',
      'items', '[]'::jsonb
    );
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'name', COALESCE(
          NULLIF(oi.display_name, ''), NULLIF(oi.label, ''),
          NULLIF(mi.name, ''), 'Item'
        ),
        'name_ko', COALESCE(
          NULLIF(mi.name_ko, ''), NULLIF(oi.display_name, ''),
          NULLIF(oi.label, ''), NULLIF(mi.name, ''), '메뉴'
        ),
        'name_vi', COALESCE(
          NULLIF(mi.name_vi, ''), NULLIF(oi.display_name, ''),
          NULLIF(oi.label, ''), NULLIF(mi.name, ''), 'Món ăn'
        ),
        'name_en', COALESCE(
          NULLIF(mi.name_en, ''), NULLIF(oi.display_name, ''),
          NULLIF(oi.label, ''), NULLIF(mi.name, ''), 'Item'
        ),
        'quantity', oi.quantity,
        'status', oi.status,
        'served_quantity', CASE
          WHEN v_order.fulfillment_mode_snapshot = 'paperless'
            THEN LEAST(
              oi.quantity,
              GREATEST(COALESCE(progress.floor_served_quantity, 0), 0)
            )
          ELSE 0
        END
      )
      ORDER BY oi.created_at, oi.id
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM public.order_items oi
  LEFT JOIN public.menu_items mi
    ON mi.id = oi.menu_item_id
   AND mi.restaurant_id = oi.restaurant_id
  LEFT JOIN LATERAL (
    SELECT item.floor_served_quantity
    FROM public.emergency_fulfillment_items item
    JOIN public.emergency_fulfillment_sessions session
      ON session.id = item.session_id
    WHERE item.order_item_id = oi.id
      AND item.restaurant_id = v_table.restaurant_id
      AND item.is_cancelled = false
    ORDER BY session.activated_at DESC, item.created_at DESC
    LIMIT 1
  ) progress ON true
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

COMMENT ON FUNCTION public.qr_get_active_order(text) IS
  'Returns the unpaid token-backed order; paperless orders include floor-delivery progress.';

COMMIT;
