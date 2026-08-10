BEGIN;

-- A public QR customer may only read the still-open order for the table
-- resolved by that same active QR token. No order/table identifier is accepted
-- from the caller, so an anonymous client cannot use this RPC to enumerate
-- another table's order.
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
      'items', '[]'::jsonb
    );
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'name', COALESCE(
          NULLIF(oi.display_name, ''),
          NULLIF(oi.label, ''),
          NULLIF(mi.name, ''),
          'Item'
        ),
        'name_ko', COALESCE(
          NULLIF(mi.name_ko, ''),
          NULLIF(oi.display_name, ''),
          NULLIF(oi.label, ''),
          NULLIF(mi.name, ''),
          '메뉴'
        ),
        'name_vi', COALESCE(
          NULLIF(mi.name_vi, ''),
          NULLIF(oi.display_name, ''),
          NULLIF(oi.label, ''),
          NULLIF(mi.name, ''),
          'Món ăn'
        ),
        'name_en', COALESCE(
          NULLIF(mi.name_en, ''),
          NULLIF(oi.display_name, ''),
          NULLIF(oi.label, ''),
          NULLIF(mi.name, ''),
          'Item'
        ),
        'quantity', oi.quantity,
        'status', oi.status
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
  WHERE oi.order_id = v_order.id
    AND oi.restaurant_id = v_table.restaurant_id
    AND oi.status <> 'cancelled'
    AND oi.item_type = 'menu_item'
    AND COALESCE(oi.is_service_item, false) = false;

  RETURN jsonb_build_object(
    'active', true,
    'order_code', substring(v_order.id::text from 1 for 8),
    'status', v_order.status,
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public.qr_get_active_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_get_active_order(text)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.qr_get_active_order(text) IS
  'Returns the active customer-visible order summary for the table resolved exclusively from an active QR token.';

COMMIT;
