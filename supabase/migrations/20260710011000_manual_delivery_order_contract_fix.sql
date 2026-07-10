-- Close manual delivery order reliability, print identity, and reporting gaps.

ALTER TABLE public.pos_client_mutation_attempts
  DROP CONSTRAINT IF EXISTS pos_client_mutation_attempts_mutation_type_check;

ALTER TABLE public.pos_client_mutation_attempts
  ADD CONSTRAINT pos_client_mutation_attempts_mutation_type_check
  CHECK (
    mutation_type IN (
      'create_order',
      'add_items_to_order',
      'create_delivery_order'
    )
  );

CREATE OR REPLACE FUNCTION public.apply_delivery_print_identity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  IF NEW.order_id IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.orders o
       WHERE o.id = NEW.order_id
         AND o.restaurant_id = NEW.restaurant_id
         AND o.sales_channel = 'delivery'
     ) THEN
    NEW.payload := COALESCE(NEW.payload, '{}'::jsonb) || jsonb_build_object(
      'sales_channel', 'delivery',
      'table_number', 'DELIVERY',
      'floor_label', 'DELIVERY'
    );
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_delivery_print_identity() FROM PUBLIC;

DROP TRIGGER IF EXISTS print_jobs_delivery_identity
  ON public.print_jobs;

CREATE TRIGGER print_jobs_delivery_identity
BEFORE INSERT OR UPDATE OF order_id, restaurant_id, payload
ON public.print_jobs
FOR EACH ROW
EXECUTE FUNCTION public.apply_delivery_print_identity();

UPDATE public.print_jobs pj
SET payload = COALESCE(pj.payload, '{}'::jsonb) || jsonb_build_object(
  'sales_channel', 'delivery',
  'table_number', 'DELIVERY',
  'floor_label', 'DELIVERY'
)
FROM public.orders o
WHERE o.id = pj.order_id
  AND o.restaurant_id = pj.restaurant_id
  AND o.sales_channel = 'delivery';

DROP FUNCTION IF EXISTS public.create_delivery_order(uuid, jsonb);

CREATE OR REPLACE FUNCTION public.create_delivery_order(
  p_store_id uuid,
  p_items jsonb,
  p_client_mutation_id text
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_client_mutation_id text;
  v_existing public.pos_client_mutation_attempts%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_item_count integer := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'cashier' THEN
    RAISE EXCEPTION 'DELIVERY_ORDER_CREATE_FORBIDDEN';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) s(store_id)
    WHERE s.store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'DELIVERY_ORDER_CREATE_FORBIDDEN';
  END IF;

  IF p_items IS NULL
     OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE jsonb_typeof(item) <> 'object'
       OR COALESCE(item->>'menu_item_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR CASE
            WHEN length(COALESCE(item->>'quantity', '')) BETWEEN 1 AND 10
             AND COALESCE(item->>'quantity', '') ~ '^[0-9]+$'
            THEN (item->>'quantity')::numeric NOT BETWEEN 1 AND 2147483647
            ELSE true
          END
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

  v_client_mutation_id := NULLIF(
    btrim(COALESCE(p_client_mutation_id, '')),
    ''
  );
  IF v_client_mutation_id IS NULL THEN
    RAISE EXCEPTION 'CLIENT_MUTATION_ID_REQUIRED';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(
      'create_delivery_order:'
      || p_store_id::text
      || ':'
      || auth.uid()::text
      || ':'
      || v_client_mutation_id
    )
  );

  SELECT *
  INTO v_existing
  FROM public.pos_client_mutation_attempts
  WHERE store_id = p_store_id
    AND actor_id = auth.uid()
    AND client_mutation_id = v_client_mutation_id
  LIMIT 1;

  IF FOUND THEN
    IF v_existing.mutation_type <> 'create_delivery_order' THEN
      RAISE EXCEPTION 'CLIENT_MUTATION_ID_CONFLICT';
    END IF;

    SELECT *
    INTO v_order
    FROM public.orders
    WHERE id = v_existing.entity_id
      AND restaurant_id = p_store_id
      AND sales_channel = 'delivery';

    IF FOUND THEN
      RETURN v_order;
    END IF;

    RAISE EXCEPTION 'CLIENT_MUTATION_RESULT_NOT_FOUND';
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

  INSERT INTO public.pos_client_mutation_attempts (
    store_id,
    actor_id,
    client_mutation_id,
    mutation_type,
    entity_type,
    entity_id,
    result_payload
  )
  VALUES (
    p_store_id,
    auth.uid(),
    v_client_mutation_id,
    'create_delivery_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'order_id', v_order.id,
      'item_count', v_item_count
    )
  );

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
      'item_count', v_item_count,
      'client_mutation_id', v_client_mutation_id
    )
  );

  RETURN v_order;
END;
$$;

REVOKE ALL ON FUNCTION public.create_delivery_order(uuid, jsonb, text)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_delivery_order(uuid, jsonb, text)
  TO authenticated;

COMMENT ON FUNCTION public.create_delivery_order(uuid, jsonb, text) IS
  'Creates an idempotent cashier-entered delivery order; separate from Deliberry.';

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
      OR (
        o.sales_channel = 'delivery'
        AND v_query IN ('delivery', '배달', 'giao hàng', 'giao hang')
      )
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

CREATE OR REPLACE VIEW public.v_daily_revenue_by_channel
WITH (security_invoker = true) AS
SELECT
  COALESCE(pos.restaurant_id, del.restaurant_id) AS restaurant_id,
  COALESCE(pos.sale_date, del.sale_date) AS sale_date,
  COALESCE(pos.dine_in_revenue, 0) AS dine_in_revenue,
  COALESCE(pos.dine_in_orders, 0) AS dine_in_orders,
  COALESCE(pos.takeaway_revenue, 0) AS takeaway_revenue,
  COALESCE(pos.takeaway_orders, 0) AS takeaway_orders,
  COALESCE(pos.delivery_revenue, 0)
    + COALESCE(del.delivery_revenue, 0) AS delivery_revenue,
  COALESCE(pos.delivery_orders, 0)
    + COALESCE(del.delivery_orders, 0) AS delivery_orders,
  COALESCE(pos.dine_in_revenue, 0)
    + COALESCE(pos.takeaway_revenue, 0)
    + COALESCE(pos.delivery_revenue, 0)
    + COALESCE(del.delivery_revenue, 0) AS total_revenue,
  COALESCE(pos.restaurant_id, del.restaurant_id) AS store_id
FROM (
  SELECT
    o.restaurant_id,
    (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS sale_date,
    SUM(CASE WHEN o.sales_channel = 'dine_in' THEN p.amount ELSE 0 END)
      AS dine_in_revenue,
    COUNT(CASE WHEN o.sales_channel = 'dine_in' THEN 1 END)
      AS dine_in_orders,
    SUM(CASE WHEN o.sales_channel = 'takeaway' THEN p.amount ELSE 0 END)
      AS takeaway_revenue,
    COUNT(CASE WHEN o.sales_channel = 'takeaway' THEN 1 END)
      AS takeaway_orders,
    SUM(CASE WHEN o.sales_channel = 'delivery' THEN p.amount ELSE 0 END)
      AS delivery_revenue,
    COUNT(CASE WHEN o.sales_channel = 'delivery' THEN 1 END)
      AS delivery_orders
  FROM public.orders o
  JOIN public.payments p ON p.order_id = o.id
  WHERE o.status = 'completed'
    AND p.is_revenue = true
  GROUP BY
    o.restaurant_id,
    (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
) pos
FULL OUTER JOIN (
  SELECT
    restaurant_id,
    (completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS sale_date,
    SUM(gross_amount) AS delivery_revenue,
    COUNT(*) AS delivery_orders
  FROM public.external_sales
  WHERE is_revenue = true
    AND order_status = 'completed'
  GROUP BY
    restaurant_id,
    (completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
) del
ON pos.restaurant_id = del.restaurant_id
AND pos.sale_date = del.sale_date;

GRANT SELECT ON public.v_daily_revenue_by_channel TO authenticated;
