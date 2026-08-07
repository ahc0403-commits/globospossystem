-- Let cashiers cancel unpaid orders/items while preserving an append-only
-- server-calculated snapshot of the payable amount removed by each action.

CREATE TABLE IF NOT EXISTS public.order_cancellation_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  order_item_id uuid REFERENCES public.order_items(id),
  cancellation_scope text NOT NULL CHECK (cancellation_scope IN ('order', 'item')),
  cancelled_amount numeric(15,2) NOT NULL CHECK (cancelled_amount >= 0),
  quantity integer,
  unit_price numeric(15,2),
  amount_basis text NOT NULL DEFAULT 'paying_amount_inc_tax_or_unit_price_x_quantity',
  item_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (cancellation_scope = 'order' AND order_item_id IS NULL)
    OR (cancellation_scope = 'item' AND order_item_id IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS order_cancellation_ledger_order_once_idx
  ON public.order_cancellation_ledger(order_id)
  WHERE cancellation_scope = 'order';

CREATE UNIQUE INDEX IF NOT EXISTS order_cancellation_ledger_item_once_idx
  ON public.order_cancellation_ledger(order_item_id)
  WHERE cancellation_scope = 'item';

CREATE INDEX IF NOT EXISTS order_cancellation_ledger_store_created_idx
  ON public.order_cancellation_ledger(restaurant_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.prevent_order_cancellation_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RAISE EXCEPTION 'ORDER_CANCELLATION_LEDGER_IMMUTABLE';
END;
$$;

DROP TRIGGER IF EXISTS order_cancellation_ledger_immutable
  ON public.order_cancellation_ledger;
CREATE TRIGGER order_cancellation_ledger_immutable
BEFORE UPDATE OR DELETE ON public.order_cancellation_ledger
FOR EACH ROW EXECUTE FUNCTION public.prevent_order_cancellation_ledger_mutation();

ALTER TABLE public.order_cancellation_ledger ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS order_cancellation_ledger_store_select
  ON public.order_cancellation_ledger;
CREATE POLICY order_cancellation_ledger_store_select
ON public.order_cancellation_ledger
FOR SELECT
TO authenticated
USING (
  public.is_super_admin()
  OR EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) s(store_id)
    WHERE s.store_id = restaurant_id
  )
);

REVOKE ALL ON TABLE public.order_cancellation_ledger FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.order_cancellation_ledger TO authenticated;
GRANT ALL ON TABLE public.order_cancellation_ledger TO service_role;

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
  v_cancelled_amount numeric(15,2) := 0;
  v_item_snapshot jsonb := '[]'::jsonb;
  v_ledger_id uuid;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'cashier', 'admin', 'store_admin', 'super_admin') THEN
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

  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'ORDER_HAS_PAYMENTS_USE_ADJUSTMENT';
  END IF;

  IF v_order.status = 'serving'
     AND v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'super_admin') THEN
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

  SELECT
    COALESCE(sum(
      CASE
        WHEN oi.is_service_item THEN 0
        WHEN COALESCE(oi.paying_amount_inc_tax, 0) > 0
          THEN oi.paying_amount_inc_tax
        ELSE oi.unit_price * oi.quantity
      END
    ), 0)::numeric(15,2),
    COALESCE(jsonb_agg(
      jsonb_build_object(
        'order_item_id', oi.id,
        'label', oi.label,
        'item_type', oi.item_type,
        'status', oi.status,
        'quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'paying_amount_inc_tax', oi.paying_amount_inc_tax,
        'is_service_item', oi.is_service_item
      ) ORDER BY oi.created_at, oi.id
    ), '[]'::jsonb)
  INTO v_cancelled_amount, v_item_snapshot
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id
    AND oi.status <> 'cancelled';

  INSERT INTO public.order_cancellation_ledger (
    restaurant_id,
    order_id,
    cancellation_scope,
    cancelled_amount,
    item_snapshot,
    created_by
  ) VALUES (
    p_store_id,
    p_order_id,
    'order',
    v_cancelled_amount,
    v_item_snapshot,
    auth.uid()
  )
  RETURNING id INTO v_ledger_id;

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
      'cancelled_item_count', v_cancelled_items,
      'cancelled_amount', v_cancelled_amount,
      'cancellation_ledger_id', v_ledger_id
    )
  );

  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_order_item(
  p_item_id uuid,
  p_store_id uuid
) RETURNS public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_order_status text;
  v_from_status text;
  v_cancelled_amount numeric(15,2);
  v_ledger_id uuid;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'cashier', 'admin', 'store_admin', 'super_admin') THEN
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
  INTO v_item
  FROM public.order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM public.orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id = v_item.order_id) THEN
    RAISE EXCEPTION 'ORDER_HAS_PAYMENTS_USE_ADJUSTMENT';
  END IF;

  IF v_item.status NOT IN ('pending', 'preparing', 'ready') THEN
    RAISE EXCEPTION 'ITEM_NOT_CANCELLABLE';
  END IF;

  v_cancelled_amount := CASE
    WHEN v_item.is_service_item THEN 0
    WHEN COALESCE(v_item.paying_amount_inc_tax, 0) > 0
      THEN v_item.paying_amount_inc_tax
    ELSE v_item.unit_price * v_item.quantity
  END;

  INSERT INTO public.order_cancellation_ledger (
    restaurant_id,
    order_id,
    order_item_id,
    cancellation_scope,
    cancelled_amount,
    quantity,
    unit_price,
    item_snapshot,
    created_by
  ) VALUES (
    p_store_id,
    v_item.order_id,
    v_item.id,
    'item',
    v_cancelled_amount,
    v_item.quantity,
    v_item.unit_price,
    jsonb_build_array(jsonb_build_object(
      'order_item_id', v_item.id,
      'label', v_item.label,
      'item_type', v_item.item_type,
      'status', v_item.status,
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price,
      'paying_amount_inc_tax', v_item.paying_amount_inc_tax,
      'is_service_item', v_item.is_service_item
    )),
    auth.uid()
  )
  RETURNING id INTO v_ledger_id;

  v_from_status := v_item.status;

  UPDATE public.order_items
  SET status = 'cancelled'
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  PERFORM public.recalc_order_status(v_item.order_id);
  PERFORM public.void_active_order_discount_for_item_change(
    v_item.order_id,
    p_store_id,
    'order_items_changed'
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order_item',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_item.order_id,
      'from_status', v_from_status,
      'to_status', 'cancelled',
      'label', v_item.label,
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price,
      'cancelled_amount', v_cancelled_amount,
      'cancellation_ledger_id', v_ledger_id
    )
  );

  RETURN v_item;
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_order(uuid, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_order(uuid, uuid, boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cancel_order_item(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_order_item(uuid, uuid) TO authenticated, service_role;

COMMENT ON TABLE public.order_cancellation_ledger IS
  'Append-only server-side monetary snapshots for unpaid order and item cancellations.';
