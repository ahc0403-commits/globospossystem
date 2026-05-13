-- ============================================================
-- POS Operational Stability Closure
-- 2026-05-13
--
-- Adds backend idempotency anchors for locally queued order sends and
-- read-only inventory reconciliation for kitchen consumption versus stock
-- audit/receipt movement. Existing order and inventory mutation contracts
-- remain the source of truth.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.pos_client_mutation_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  actor_id UUID NULL REFERENCES auth.users(id),
  client_mutation_id TEXT NOT NULL,
  mutation_type TEXT NOT NULL CHECK (
    mutation_type IN ('create_order', 'add_items_to_order')
  ),
  entity_type TEXT NOT NULL,
  entity_id UUID NULL,
  result_payload JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (store_id, actor_id, client_mutation_id)
);

CREATE INDEX IF NOT EXISTS idx_pos_client_mutation_attempts_store_created
  ON public.pos_client_mutation_attempts (store_id, created_at DESC);

ALTER TABLE public.pos_client_mutation_attempts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pos_client_mutation_attempts_scoped_read
  ON public.pos_client_mutation_attempts;

CREATE POLICY pos_client_mutation_attempts_scoped_read
  ON public.pos_client_mutation_attempts
  FOR SELECT
  TO authenticated
  USING (
    auth.role() = 'service_role'
    OR (
      actor_id = auth.uid()
      AND (
        public.is_super_admin()
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id = pos_client_mutation_attempts.store_id
        )
      )
    )
  );

CREATE OR REPLACE FUNCTION public.create_order_with_client_mutation_id(
  p_store_id UUID,
  p_table_id UUID,
  p_items JSONB,
  p_client_mutation_id TEXT
) RETURNS public.orders AS $$
DECLARE
  v_client_mutation_id TEXT;
  v_existing public.pos_client_mutation_attempts%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_order_id UUID;
BEGIN
  v_client_mutation_id := NULLIF(btrim(COALESCE(p_client_mutation_id, '')), '');

  IF v_client_mutation_id IS NULL THEN
    RAISE EXCEPTION 'CLIENT_MUTATION_ID_REQUIRED';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext('create_order:' || p_store_id::TEXT || ':' || auth.uid()::TEXT || ':' || v_client_mutation_id)
  );

  SELECT *
  INTO v_existing
  FROM public.pos_client_mutation_attempts
  WHERE store_id = p_store_id
    AND actor_id = auth.uid()
    AND client_mutation_id = v_client_mutation_id
    AND mutation_type = 'create_order'
  LIMIT 1;

  IF FOUND THEN
    SELECT *
    INTO v_order
    FROM public.orders
    WHERE id = v_existing.entity_id
      AND restaurant_id = p_store_id;

    IF FOUND THEN
      RETURN v_order;
    END IF;
  END IF;

  SELECT *
  INTO v_order
  FROM public.create_order(p_store_id, p_table_id, p_items);

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
    'create_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'order_id', v_order.id,
      'table_id', p_table_id,
      'item_count', jsonb_array_length(p_items)
    )
  )
  ON CONFLICT (store_id, actor_id, client_mutation_id)
  DO UPDATE SET
    updated_at = now()
  RETURNING entity_id INTO v_order_id;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = v_order_id
    AND restaurant_id = p_store_id;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.add_items_to_order_with_client_mutation_id(
  p_order_id UUID,
  p_store_id UUID,
  p_items JSONB,
  p_client_mutation_id TEXT
) RETURNS SETOF public.order_items AS $$
DECLARE
  v_client_mutation_id TEXT;
  v_existing public.pos_client_mutation_attempts%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_inserted_item_ids UUID[] := ARRAY[]::UUID[];
BEGIN
  v_client_mutation_id := NULLIF(btrim(COALESCE(p_client_mutation_id, '')), '');

  IF v_client_mutation_id IS NULL THEN
    RAISE EXCEPTION 'CLIENT_MUTATION_ID_REQUIRED';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext('add_items_to_order:' || p_order_id::TEXT || ':' || auth.uid()::TEXT || ':' || v_client_mutation_id)
  );

  SELECT *
  INTO v_existing
  FROM public.pos_client_mutation_attempts
  WHERE store_id = p_store_id
    AND actor_id = auth.uid()
    AND client_mutation_id = v_client_mutation_id
    AND mutation_type = 'add_items_to_order'
  LIMIT 1;

  IF FOUND THEN
    RETURN QUERY
    SELECT *
    FROM public.order_items
    WHERE id IN (
      SELECT value::UUID
      FROM jsonb_array_elements_text(
        COALESCE(v_existing.result_payload->'order_item_ids', '[]'::JSONB)
      )
    )
      AND restaurant_id = p_store_id;
    RETURN;
  END IF;

  FOR v_item IN
    SELECT *
    FROM public.add_items_to_order(p_order_id, p_store_id, p_items)
  LOOP
    v_inserted_item_ids := array_append(v_inserted_item_ids, v_item.id);
    RETURN NEXT v_item;
  END LOOP;

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
    'add_items_to_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'order_id', p_order_id,
      'order_item_ids', to_jsonb(v_inserted_item_ids),
      'item_count', COALESCE(array_length(v_inserted_item_ids, 1), 0)
    )
  );

  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_inventory_kitchen_stock_reconciliation(
  p_store_id UUID,
  p_from DATE DEFAULT CURRENT_DATE - 6,
  p_to DATE DEFAULT CURRENT_DATE
) RETURNS JSONB AS $$
DECLARE
  v_lines JSONB := '[]'::JSONB;
  v_mismatch_count INTEGER := 0;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECONCILIATION_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_RECONCILIATION_DATE_RANGE_INVALID';
  END IF;

  WITH consumption AS (
    SELECT
      product_id,
      SUM(consumed_quantity_base)::NUMERIC(12,3) AS consumed_quantity_base,
      SUM(consumed_amount)::NUMERIC(12,2) AS consumed_amount
    FROM public.inventory_daily_consumption
    WHERE restaurant_id = p_store_id
      AND source = 'pos'
      AND consumption_date BETWEEN p_from AND p_to
    GROUP BY product_id
  ),
  movement AS (
    SELECT
      ip.id AS product_id,
      SUM(CASE
        WHEN it.reference_type = 'inventory_purchase_receipt' THEN it.quantity_g
        ELSE 0
      END)::NUMERIC(12,3) AS receipt_quantity_base,
      SUM(CASE
        WHEN it.reference_type = 'inventory_stock_audit' THEN it.quantity_g
        ELSE 0
      END)::NUMERIC(12,3) AS audit_adjustment_quantity_base
    FROM public.inventory_transactions it
    JOIN public.inventory_products ip
      ON ip.inventory_item_id = it.ingredient_id
     AND ip.restaurant_id = it.restaurant_id
    WHERE it.restaurant_id = p_store_id
      AND it.created_at::DATE BETWEEN p_from AND p_to
      AND it.reference_type IN (
        'inventory_purchase_receipt',
        'inventory_stock_audit'
      )
    GROUP BY ip.id
  ),
  joined AS (
    SELECT
      ip.id AS product_id,
      ip.name AS product_name,
      COALESCE(consumption.consumed_quantity_base, 0) AS consumed_quantity_base,
      COALESCE(consumption.consumed_amount, 0) AS consumed_amount,
      COALESCE(movement.receipt_quantity_base, 0) AS receipt_quantity_base,
      COALESCE(movement.audit_adjustment_quantity_base, 0) AS audit_adjustment_quantity_base,
      (
        COALESCE(consumption.consumed_quantity_base, 0)
        - COALESCE(movement.receipt_quantity_base, 0)
        - COALESCE(movement.audit_adjustment_quantity_base, 0)
      )::NUMERIC(12,3) AS reconciliation_gap_base
    FROM public.inventory_products ip
    LEFT JOIN consumption
      ON consumption.product_id = ip.id
    LEFT JOIN movement
      ON movement.product_id = ip.id
    WHERE ip.restaurant_id = p_store_id
      AND (
        consumption.product_id IS NOT NULL
        OR movement.product_id IS NOT NULL
      )
  )
  SELECT
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'product_id', product_id,
          'product_name', product_name,
          'consumed_quantity_base', consumed_quantity_base,
          'consumed_amount', consumed_amount,
          'receipt_quantity_base', receipt_quantity_base,
          'audit_adjustment_quantity_base', audit_adjustment_quantity_base,
          'reconciliation_gap_base', reconciliation_gap_base,
          'status', CASE
            WHEN ABS(reconciliation_gap_base) >= 1000 THEN 'mismatch'
            WHEN ABS(reconciliation_gap_base) > 0 THEN 'watch'
            ELSE 'aligned'
          END
        )
        ORDER BY ABS(reconciliation_gap_base) DESC, product_name ASC
      ),
      '[]'::JSONB
    ),
    COUNT(*) FILTER (WHERE ABS(reconciliation_gap_base) >= 1000)
  INTO v_lines, v_mismatch_count
  FROM joined;

  RETURN jsonb_build_object(
    'store_id', p_store_id,
    'from', p_from,
    'to', p_to,
    'mismatch_count', COALESCE(v_mismatch_count, 0),
    'lines', v_lines
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.create_order_with_client_mutation_id(UUID, UUID, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_items_to_order_with_client_mutation_id(UUID, UUID, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_inventory_kitchen_stock_reconciliation(UUID, DATE, DATE) TO authenticated;
