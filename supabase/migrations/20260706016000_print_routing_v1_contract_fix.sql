-- Re-apply the print routing serving/cancel contract for environments that
-- already recorded 20260706014000 before its final function bodies landed.

CREATE OR REPLACE FUNCTION public.recalc_order_status(
  p_order_id uuid
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_order public.orders%ROWTYPE;
  v_active int;
  v_done int;
  v_started int;
  v_next text;
  v_tray_batch_no int;
  v_tray_items jsonb := '[]'::jsonb;
BEGIN
  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RETURN;
  END IF;

  SELECT
    count(*) FILTER (WHERE status <> 'cancelled'),
    count(*) FILTER (WHERE status IN ('ready', 'served')),
    count(*) FILTER (WHERE status IN ('preparing', 'ready', 'served'))
  INTO v_active, v_done, v_started
  FROM public.order_items
  WHERE order_id = p_order_id;

  IF v_active = 0 THEN
    v_next := 'cancelled';
  ELSIF v_done = v_active THEN
    v_next := 'serving';
  ELSIF v_started > 0 THEN
    v_next := 'confirmed';
  ELSE
    v_next := 'pending';
  END IF;

  IF v_next = v_order.status THEN
    UPDATE public.orders SET updated_at = now() WHERE id = p_order_id;
    RETURN;
  END IF;

  UPDATE public.orders
  SET status = v_next,
      updated_at = now()
  WHERE id = p_order_id;

  IF v_next = 'cancelled' AND v_order.table_id IS NOT NULL THEN
    UPDATE public.tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.orders o
        WHERE o.table_id = v_order.table_id
          AND o.id <> p_order_id
          AND o.status IN ('pending', 'confirmed', 'serving')
      );
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'recalc_order_status',
    'orders',
    p_order_id,
    jsonb_build_object(
      'from_status', v_order.status,
      'to_status', v_next
    )
  );

  IF v_next = 'serving' AND v_order.status <> 'serving' THEN
    SELECT COALESCE(MAX(batch_no), 0) + 1
    INTO v_tray_batch_no
    FROM public.print_jobs
    WHERE order_id = p_order_id
      AND copy_type = 'tray';

    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'item_id', oi.id::text,
          'label', COALESCE(NULLIF(oi.label, ''), NULLIF(oi.display_name, ''), 'Item'),
          'quantity', oi.quantity,
          'notes', oi.notes,
          'supplemental', v_tray_batch_no > 1 OR oi.created_at > v_order.created_at + interval '10 seconds'
        )
        ORDER BY oi.created_at, oi.id
      ),
      '[]'::jsonb
    )
    INTO v_tray_items
    FROM public.order_items oi
    WHERE oi.order_id = p_order_id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
      AND (
        v_tray_batch_no = 1
        OR NOT EXISTS (
          SELECT 1
          FROM public.print_jobs prior
          CROSS JOIN LATERAL jsonb_array_elements(
            COALESCE(prior.payload->'items', '[]'::jsonb)
          ) AS prior_item(raw)
          WHERE prior.order_id = p_order_id
            AND prior.copy_type = 'tray'
            AND prior.status <> 'cancelled'
            AND NULLIF(prior_item.raw->>'item_id', '') = oi.id::text
        )
      );

    IF jsonb_array_length(v_tray_items) > 0 THEN
      PERFORM public.enqueue_print_jobs(
        p_order_id,
        ARRAY['tray'],
        v_tray_items,
        'serving'
      );
    END IF;
  END IF;
END;
$$;

DROP FUNCTION IF EXISTS public.cancel_order(uuid, uuid);

CREATE OR REPLACE FUNCTION public.cancel_order(
  p_order_id uuid,
  p_store_id uuid,
  p_allow_served boolean DEFAULT false
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_from_status text;
  v_cancelled_items int := 0;
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
    RAISE EXCEPTION 'ORDER_NOT_CANCELLABLE';
  END IF;

  IF v_order.status = 'serving'
     AND v_actor.role NOT IN ('admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_SERVING_CANCEL_ADMIN_REQUIRED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_items
    WHERE order_id = p_order_id
      AND status = 'served'
  ) AND NOT COALESCE(p_allow_served, false) THEN
    RAISE EXCEPTION 'ORDER_HAS_SERVED_ITEMS';
  END IF;

  v_from_status := v_order.status;

  UPDATE public.order_items
  SET status = 'cancelled'
  WHERE order_id = p_order_id
    AND status IN ('pending', 'preparing', 'ready');
  GET DIAGNOSTICS v_cancelled_items = ROW_COUNT;

  UPDATE public.orders
  SET status = 'cancelled',
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  UPDATE public.print_jobs
  SET status = 'cancelled',
      updated_at = now()
  WHERE order_id = p_order_id
    AND status IN ('pending', 'failed');

  IF v_order.table_id IS NOT NULL THEN
    UPDATE public.tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.orders o
        WHERE o.table_id = v_order.table_id
          AND o.id <> p_order_id
          AND o.status IN ('pending', 'confirmed', 'serving')
      );
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'from_status', v_from_status,
      'to_status', 'cancelled',
      'cancelled_item_count', v_cancelled_items
    )
  );

  RETURN v_order;
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_order(uuid, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_order(uuid, uuid, boolean) TO authenticated, service_role;
