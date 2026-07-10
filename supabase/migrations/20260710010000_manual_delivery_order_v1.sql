-- Manual delivery orders entered by cashiers for third-party platforms.
-- This flow is intentionally separate from Deliberry operational/settlement data.

CREATE OR REPLACE FUNCTION public.create_delivery_order(
  p_store_id uuid,
  p_items jsonb
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_item_count integer := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'DELIVERY_ORDER_CREATE_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'DELIVERY_ORDER_CREATE_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::integer, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN public.menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = true
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO public.orders (
    restaurant_id,
    table_id,
    sales_channel,
    status,
    created_by,
    order_source,
    order_purpose
  )
  VALUES (
    p_store_id,
    NULL,
    'delivery',
    'pending',
    auth.uid(),
    'staff',
    'customer'
  )
  RETURNING * INTO v_order;

  INSERT INTO public.order_items (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    display_name,
    restaurant_id,
    item_type
  )
  SELECT
    v_order.id,
    m.id,
    (item->>'quantity')::integer,
    m.price,
    m.name,
    m.name,
    p_store_id,
    'menu_item'
  FROM jsonb_array_elements(p_items) item
  JOIN public.menu_items m
    ON m.id = (item->>'menu_item_id')::uuid
   AND m.restaurant_id = p_store_id
   AND m.is_available = true;

  GET DIAGNOSTICS v_item_count = ROW_COUNT;

  PERFORM public.enqueue_print_jobs(
    v_order.id,
    ARRAY['kitchen'],
    p_items,
    'initial'
  );

  UPDATE public.print_jobs
  SET payload = payload || jsonb_build_object(
    'sales_channel', 'delivery',
    'table_number', 'DELIVERY',
    'floor_label', 'DELIVERY'
  )
  WHERE order_id = v_order.id;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  VALUES (
    auth.uid(),
    'create_delivery_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'sales_channel', 'delivery',
      'item_count', v_item_count
    )
  );

  RETURN v_order;
END;
$$;

REVOKE ALL ON FUNCTION public.create_delivery_order(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_delivery_order(uuid, jsonb) TO authenticated;

COMMENT ON FUNCTION public.create_delivery_order(uuid, jsonb) IS
  'Creates a cashier-entered delivery order for kitchen preparation; separate from Deliberry.';

CREATE OR REPLACE FUNCTION public.search_active_order_for_cashier(
  p_store_id uuid,
  p_query text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_query text := lower(replace(btrim(COALESCE(p_query, '')), '#', ''));
  v_result jsonb;
BEGIN
  IF p_store_id IS NULL OR v_query = '' THEN
    RETURN NULL;
  END IF;

  IF NOT (
    public.is_super_admin()
    OR EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = p_store_id
    )
  ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_DENIED';
  END IF;

  SELECT jsonb_build_object(
    'id', o.id::text,
    'table_id', o.table_id::text,
    'status', o.status,
    'sales_channel', o.sales_channel,
    'order_purpose', o.order_purpose,
    'order_source', o.order_source,
    'created_at', o.created_at,
    'tables', jsonb_build_object(
      'table_number',
      CASE
        WHEN o.sales_channel = 'delivery' THEN 'DELIVERY'
        WHEN o.order_purpose = 'staff_meal' THEN 'STAFF'
        ELSE COALESCE(t.table_number, '-')
      END
    )
  )
  INTO v_result
  FROM public.orders o
  LEFT JOIN public.tables t
    ON t.id = o.table_id
   AND t.restaurant_id = o.restaurant_id
  WHERE o.restaurant_id = p_store_id
    AND o.status IN ('pending', 'confirmed', 'serving')
    AND (
      lower(substring(o.id::text from 1 for 8)) = v_query
      OR lower(o.id::text) LIKE v_query || '%'
      OR lower(COALESCE(t.table_number, '')) = v_query
      OR lower(COALESCE(t.table_number, '')) LIKE '%' || v_query || '%'
      OR (o.sales_channel = 'delivery' AND v_query IN ('delivery', '배달'))
    )
  ORDER BY
    CASE
      WHEN lower(substring(o.id::text from 1 for 8)) = v_query THEN 0
      WHEN lower(COALESCE(t.table_number, '')) = v_query THEN 1
      WHEN lower(o.id::text) LIKE v_query || '%' THEN 2
      ELSE 3
    END,
    o.created_at DESC
  LIMIT 1;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.search_active_order_for_cashier(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.search_active_order_for_cashier(uuid, text)
  TO authenticated, service_role;
