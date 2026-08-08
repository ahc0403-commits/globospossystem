-- QR additions must print the exact order_items inserted by this call. The
-- request payload has no immutable order_item IDs, so using it for printing
-- lets later label normalization resolve an additional line to an older line.

CREATE OR REPLACE FUNCTION public.qr_place_order(
  p_token text,
  p_items jsonb,
  p_client_order_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_existing_batch public.qr_order_batches%ROWTYPE;
  v_items jsonb := COALESCE(p_items, '[]'::jsonb);
  v_item_count int;
  v_line record;
  v_inserted_item public.order_items%ROWTYPE;
  v_live_order public.orders%ROWTYPE;
  v_order_id uuid;
  v_is_new_order boolean := false;
  v_batch_no int;
  v_items_snapshot jsonb := '[]'::jsonb;
  v_print_items jsonb := '[]'::jsonb;
  v_result jsonb;
  v_print_reason text;
BEGIN
  IF p_client_order_id IS NULL THEN
    RAISE EXCEPTION 'QR_CLIENT_ORDER_ID_REQUIRED';
  END IF;

  SELECT
    q.restaurant_id,
    q.table_id,
    t.table_number,
    COALESCE(t.floor_label, '1F') AS floor_label,
    r.name AS store_name
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

  SELECT *
  INTO v_existing_batch
  FROM public.qr_order_batches
  WHERE client_order_id = p_client_order_id
    AND restaurant_id = v_table.restaurant_id
    AND table_id = v_table.table_id;

  IF FOUND THEN
    RETURN v_existing_batch.result_snapshot;
  END IF;

  IF jsonb_typeof(v_items) <> 'array' THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  v_item_count := jsonb_array_length(v_items);
  IF v_item_count < 1 OR v_item_count > 20 THEN
    RAISE EXCEPTION 'QR_ITEMS_INVALID';
  END IF;

  FOR v_line IN
    SELECT raw
    FROM jsonb_array_elements(v_items) AS line(raw)
  LOOP
    IF COALESCE(v_line.raw->>'menu_item_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RAISE EXCEPTION 'QR_ITEMS_INVALID';
    END IF;
    IF COALESCE(v_line.raw->>'quantity', '') !~ '^[0-9]+$'
       OR (v_line.raw->>'quantity')::int < 1
       OR (v_line.raw->>'quantity')::int > 20 THEN
      RAISE EXCEPTION 'QR_ITEMS_INVALID';
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM public.qr_order_batches b
    WHERE b.table_id = v_table.table_id
      AND b.created_at > now() - interval '20 seconds'
  ) THEN
    RAISE EXCEPTION 'QR_TOO_FREQUENT';
  END IF;

  WITH input_items AS (
    SELECT
      (raw->>'menu_item_id')::uuid AS menu_item_id,
      (raw->>'quantity')::int AS quantity,
      ord
    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS line(raw, ord)
  ),
  matched_items AS (
    SELECT
      i.menu_item_id,
      i.quantity,
      i.ord,
      m.name,
      m.price
    FROM input_items i
    JOIN public.menu_items m
      ON m.id = i.menu_item_id
     AND m.restaurant_id = v_table.restaurant_id
     AND m.is_available = true
     AND m.is_visible_public = true
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'menu_item_id', menu_item_id::text,
        'quantity', quantity,
        'name', name,
        'unit_price', price
      )
      ORDER BY ord
    ),
    '[]'::jsonb
  )
  INTO v_items_snapshot
  FROM matched_items;

  IF jsonb_array_length(v_items_snapshot) <> v_item_count THEN
    RAISE EXCEPTION 'QR_MENU_ITEM_UNAVAILABLE';
  END IF;

  PERFORM 1
  FROM public.tables
  WHERE id = v_table.table_id
    AND restaurant_id = v_table.restaurant_id
  FOR UPDATE;

  SELECT *
  INTO v_live_order
  FROM public.orders
  WHERE table_id = v_table.table_id
    AND restaurant_id = v_table.restaurant_id
    AND status IN ('pending', 'confirmed', 'serving')
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
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
      v_table.restaurant_id,
      v_table.table_id,
      'dine_in',
      'pending',
      NULL,
      'qr',
      'customer'
    )
    RETURNING * INTO v_live_order;

    v_is_new_order := true;

    UPDATE public.tables
    SET status = 'occupied',
        updated_at = now()
    WHERE id = v_table.table_id;
  ELSE
    IF EXISTS (
      SELECT 1
      FROM public.payments p
      WHERE p.order_id = v_live_order.id
    ) THEN
      RAISE EXCEPTION 'QR_ORDER_PAYMENT_IN_PROGRESS';
    END IF;
  END IF;

  v_order_id := v_live_order.id;

  FOR v_line IN
    SELECT item.raw, item.ord
    FROM jsonb_array_elements(v_items_snapshot)
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
    VALUES (
      v_order_id,
      (v_line.raw->>'menu_item_id')::uuid,
      (v_line.raw->>'quantity')::int,
      (v_line.raw->>'unit_price')::numeric,
      v_line.raw->>'name',
      v_line.raw->>'name',
      v_table.restaurant_id,
      'menu_item'
    )
    RETURNING * INTO v_inserted_item;

    v_print_items := v_print_items || jsonb_build_array(
      jsonb_build_object(
        'item_id', v_inserted_item.id::text,
        'menu_item_id', v_inserted_item.menu_item_id::text,
        'label', COALESCE(
          NULLIF(v_inserted_item.label, ''),
          NULLIF(v_inserted_item.display_name, ''),
          'Item'
        ),
        'quantity', v_inserted_item.quantity,
        'notes', v_inserted_item.notes,
        'supplemental', NOT v_is_new_order
      )
    );
  END LOOP;

  IF NOT v_is_new_order THEN
    PERFORM public.void_active_order_discount_for_item_change(
      v_order_id,
      v_table.restaurant_id,
      'order_items_changed'
    );
  END IF;

  PERFORM public.recalc_order_status(v_order_id);

  SELECT COALESCE(MAX(batch_no), 0) + 1
  INTO v_batch_no
  FROM public.print_jobs
  WHERE order_id = v_order_id
    AND copy_type IN ('kitchen', 'floor', 'confirmation');

  v_print_reason := CASE WHEN v_batch_no = 1 THEN 'initial' ELSE 'added_items' END;

  PERFORM public.enqueue_print_jobs(
    v_order_id,
    ARRAY['kitchen', 'floor', 'confirmation'],
    v_print_items,
    v_print_reason
  );

  v_result := jsonb_build_object(
    'order_id', v_order_id::text,
    'order_code', substring(v_order_id::text from 1 for 8),
    'batch_no', v_batch_no,
    'table_number', v_table.table_number,
    'floor_label', v_table.floor_label,
    'items', (
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'name', item->>'name',
            'quantity', (item->>'quantity')::int
          )
        ),
        '[]'::jsonb
      )
      FROM jsonb_array_elements(v_items_snapshot) item
    )
  );

  INSERT INTO public.qr_order_batches (
    restaurant_id,
    table_id,
    order_id,
    batch_no,
    client_order_id,
    items_snapshot,
    result_snapshot
  )
  VALUES (
    v_table.restaurant_id,
    v_table.table_id,
    v_order_id,
    v_batch_no,
    p_client_order_id,
    v_items_snapshot,
    v_result
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    NULL,
    'qr_place_order',
    'orders',
    v_order_id,
    jsonb_build_object(
      'store_id', v_table.restaurant_id,
      'table_id', v_table.table_id,
      'batch_no', v_batch_no,
      'client_order_id', p_client_order_id,
      'item_count', v_item_count
    )
  );

  RETURN v_result;
EXCEPTION
  WHEN unique_violation THEN
    SELECT *
    INTO v_existing_batch
    FROM public.qr_order_batches
    WHERE client_order_id = p_client_order_id
      AND restaurant_id = v_table.restaurant_id
      AND table_id = v_table.table_id;
    IF FOUND THEN
      RETURN v_existing_batch.result_snapshot;
    END IF;
    RAISE;
END;
$$;
