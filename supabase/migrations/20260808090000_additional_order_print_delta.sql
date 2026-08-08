-- Additional-order kitchen and floor tickets must contain only rows created by
-- the current add-items call. Build the print payload from the inserted rows,
-- including their immutable order_item IDs, instead of trusting the request
-- payload as the printable delta.

CREATE OR REPLACE FUNCTION public.add_items_to_order(
  p_order_id uuid,
  p_store_id uuid,
  p_items jsonb
) RETURNS SETOF public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_line record;
  v_item public.order_items%ROWTYPE;
  v_inserted_count int := 0;
  v_print_items jsonb := '[]'::jsonb;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN public.menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  FOR v_line IN
    SELECT item.raw, item.ord
    FROM jsonb_array_elements(p_items)
      WITH ORDINALITY AS item(raw, ord)
    ORDER BY item.ord
  LOOP
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
      p_order_id,
      m.id,
      (v_line.raw->>'quantity')::int,
      m.price,
      m.name,
      m.name,
      p_store_id,
      'menu_item'
    FROM public.menu_items m
    WHERE m.id = (v_line.raw->>'menu_item_id')::uuid
      AND m.restaurant_id = p_store_id
      AND m.is_available = TRUE
    RETURNING * INTO v_item;

    v_inserted_count := v_inserted_count + 1;
    v_print_items := v_print_items || jsonb_build_array(
      jsonb_build_object(
        'item_id', v_item.id::text,
        'menu_item_id', v_item.menu_item_id::text,
        'label', COALESCE(
          NULLIF(v_item.label, ''),
          NULLIF(v_item.display_name, ''),
          'Item'
        ),
        'quantity', v_item.quantity,
        'notes', v_item.notes,
        'supplemental', true,
        'components', COALESCE(v_item.combo_components, '[]'::jsonb)
      )
    );
    RETURN NEXT v_item;
  END LOOP;

  PERFORM public.recalc_order_status(p_order_id);
  PERFORM public.void_active_order_discount_for_item_change(
    p_order_id,
    p_store_id,
    'order_items_changed'
  );
  PERFORM public.enqueue_print_jobs(
    p_order_id,
    ARRAY['kitchen', 'floor'],
    v_print_items,
    'added_items'
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'add_items_to_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'added_item_count', v_inserted_count
    )
  );

  RETURN;
END;
$$;
