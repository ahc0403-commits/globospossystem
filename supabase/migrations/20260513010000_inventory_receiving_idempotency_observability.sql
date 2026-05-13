-- ============================================================
-- Inventory Receiving Idempotency + Attempt Trace + Observability
-- 2026-05-13
-- ============================================================

CREATE TABLE IF NOT EXISTS public.inventory_receipt_confirmation_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_order_id UUID NOT NULL REFERENCES public.inventory_purchase_orders(id) ON DELETE CASCADE,
  receipt_id UUID NULL REFERENCES public.inventory_receipts(id) ON DELETE SET NULL,
  restaurant_id UUID NOT NULL REFERENCES public.restaurants(id),
  actor_id UUID NULL REFERENCES auth.users(id),
  attempt_key TEXT NOT NULL,
  attempt_status TEXT NOT NULL CHECK (attempt_status IN ('succeeded', 'replayed', 'noop')),
  requested_line_count INTEGER NOT NULL DEFAULT 0,
  accepted_total_quantity_base NUMERIC(12,3) NOT NULL DEFAULT 0,
  rejected_total_quantity_base NUMERIC(12,3) NOT NULL DEFAULT 0,
  remaining_quantity_before_base NUMERIC(12,3) NOT NULL DEFAULT 0,
  remaining_quantity_after_base NUMERIC(12,3) NOT NULL DEFAULT 0,
  metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (purchase_order_id, attempt_key)
);

CREATE INDEX IF NOT EXISTS idx_inventory_receipt_attempts_order_created
  ON public.inventory_receipt_confirmation_attempts (purchase_order_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_inventory_receipt_attempts_store_created
  ON public.inventory_receipt_confirmation_attempts (restaurant_id, created_at DESC);

ALTER TABLE public.inventory_receipt_confirmation_attempts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS inventory_receipt_attempts_scoped_read
  ON public.inventory_receipt_confirmation_attempts;

CREATE POLICY inventory_receipt_attempts_scoped_read
  ON public.inventory_receipt_confirmation_attempts
  FOR SELECT
  TO authenticated
  USING (
    auth.role() = 'service_role'
    OR public.can_access_inventory_purchase_store(restaurant_id)
  );

CREATE OR REPLACE FUNCTION public.confirm_inventory_purchase_receipt(
  p_purchase_order_id UUID,
  p_memo TEXT DEFAULT NULL,
  p_lines JSONB DEFAULT '[]'::JSONB
) RETURNS public.inventory_purchase_orders AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_receipt_id UUID;
  v_line JSONB;
  v_line_id UUID;
  v_accepted_quantity_base NUMERIC(12,3);
  v_rejected_quantity_base NUMERIC(12,3);
  v_line_memo TEXT;
  v_ordered_total NUMERIC(12,3);
  v_accepted_total_before NUMERIC(12,3);
  v_accepted_total_after NUMERIC(12,3);
  v_rejected_total_this_receipt NUMERIC(12,3);
  v_accepted_total_this_receipt NUMERIC(12,3);
  v_attempt_key_normalized TEXT;
  v_requested_line_count INTEGER := 0;
  v_existing_attempt public.inventory_receipt_confirmation_attempts%ROWTYPE;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  IF v_order.status NOT IN ('office_approved', 'ordered', 'partially_received') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_RECEIVABLE';
  END IF;

  v_attempt_key_normalized := md5(
    COALESCE(auth.uid()::TEXT, 'anonymous')
    || ':' || p_purchase_order_id::TEXT
    || ':' || COALESCE(NULLIF(btrim(COALESCE(p_memo, '')), ''), '-')
    || ':' || COALESCE(p_lines::TEXT, '[]')
  );

  PERFORM pg_advisory_xact_lock(
    hashtext('confirm_inventory_purchase_receipt:' || p_purchase_order_id::TEXT || ':' || v_attempt_key_normalized)
  );

  SELECT *
  INTO v_existing_attempt
  FROM public.inventory_receipt_confirmation_attempts
  WHERE purchase_order_id = p_purchase_order_id
    AND attempt_key = v_attempt_key_normalized
  LIMIT 1;

  IF FOUND THEN
    RETURN v_order;
  END IF;

  SELECT COALESCE(SUM(ordered_quantity_base), 0)
  INTO v_ordered_total
  FROM public.inventory_purchase_order_lines
  WHERE purchase_order_id = p_purchase_order_id;

  SELECT COALESCE(SUM(irl.accepted_quantity_base), 0)
  INTO v_accepted_total_before
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_receipts ir
    ON ir.id = irl.receipt_id
   AND ir.status = 'confirmed'
  WHERE ir.purchase_order_id = p_purchase_order_id;

  IF v_ordered_total <= 0 OR v_accepted_total_before >= v_ordered_total THEN
    INSERT INTO public.inventory_receipt_confirmation_attempts (
      purchase_order_id,
      receipt_id,
      restaurant_id,
      actor_id,
      attempt_key,
      attempt_status,
      requested_line_count,
      accepted_total_quantity_base,
      rejected_total_quantity_base,
      remaining_quantity_before_base,
      remaining_quantity_after_base,
      metadata
    )
    VALUES (
      p_purchase_order_id,
      NULL,
      v_order.restaurant_id,
      auth.uid(),
      v_attempt_key_normalized,
      'replayed',
      0,
      0,
      0,
      GREATEST(v_ordered_total - v_accepted_total_before, 0),
      GREATEST(v_ordered_total - v_accepted_total_before, 0),
      jsonb_build_object('reason', 'already_received_or_empty_order')
    );

    RETURN v_order;
  END IF;

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
    v_requested_line_count := jsonb_array_length(p_lines);
  END IF;

  INSERT INTO public.inventory_receipts (
    purchase_order_id,
    restaurant_id,
    supplier_id,
    received_by,
    status,
    memo
  )
  VALUES (
    p_purchase_order_id,
    v_order.restaurant_id,
    v_order.supplier_id,
    auth.uid(),
    'confirmed',
    NULLIF(btrim(COALESCE(p_memo, '')), '')
  )
  RETURNING id INTO v_receipt_id;

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' AND jsonb_array_length(p_lines) > 0 THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
      v_line_id := NULLIF(v_line->>'line_id', '')::UUID;
      v_accepted_quantity_base := COALESCE(NULLIF(v_line->>'accepted_quantity_base', '')::NUMERIC, 0);
      v_rejected_quantity_base := COALESCE(NULLIF(v_line->>'rejected_quantity_base', '')::NUMERIC, 0);
      v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');

      INSERT INTO public.inventory_receipt_lines (
        receipt_id,
        purchase_order_line_id,
        product_id,
        received_quantity_base,
        accepted_quantity_base,
        rejected_quantity_base,
        memo
      )
      SELECT
        v_receipt_id,
        pol.id,
        pol.product_id,
        v_accepted_quantity_base + v_rejected_quantity_base,
        v_accepted_quantity_base,
        v_rejected_quantity_base,
        v_line_memo
      FROM public.inventory_purchase_order_lines pol
      WHERE pol.id = v_line_id
        AND pol.purchase_order_id = p_purchase_order_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_NOT_FOUND';
      END IF;
    END LOOP;
  ELSE
    INSERT INTO public.inventory_receipt_lines (
      receipt_id,
      purchase_order_line_id,
      product_id,
      received_quantity_base,
      accepted_quantity_base,
      rejected_quantity_base
    )
    SELECT
      v_receipt_id,
      pol.id,
      pol.product_id,
      GREATEST(pol.ordered_quantity_base - COALESCE(received.accepted_quantity_base, 0), 0),
      GREATEST(pol.ordered_quantity_base - COALESCE(received.accepted_quantity_base, 0), 0),
      0
    FROM public.inventory_purchase_order_lines pol
    LEFT JOIN (
      SELECT
        irl.purchase_order_line_id,
        SUM(irl.accepted_quantity_base) AS accepted_quantity_base
      FROM public.inventory_receipt_lines irl
      JOIN public.inventory_receipts ir
        ON ir.id = irl.receipt_id
       AND ir.status = 'confirmed'
      WHERE ir.purchase_order_id = p_purchase_order_id
      GROUP BY irl.purchase_order_line_id
    ) received
      ON received.purchase_order_line_id = pol.id
    WHERE pol.purchase_order_id = p_purchase_order_id
      AND GREATEST(pol.ordered_quantity_base - COALESCE(received.accepted_quantity_base, 0), 0) > 0;
  END IF;

  SELECT COALESCE(SUM(accepted_quantity_base), 0),
         COALESCE(SUM(rejected_quantity_base), 0)
  INTO v_accepted_total_this_receipt, v_rejected_total_this_receipt
  FROM public.inventory_receipt_lines
  WHERE receipt_id = v_receipt_id;

  UPDATE public.inventory_items ii
  SET current_stock = COALESCE(current_stock, 0) + received.accepted_quantity_base,
      quantity = COALESCE(quantity, 0) + received.accepted_quantity_base,
      updated_at = now()
  FROM (
    SELECT
      ip.inventory_item_id,
      SUM(irl.accepted_quantity_base) AS accepted_quantity_base
    FROM public.inventory_receipt_lines irl
    JOIN public.inventory_products ip
      ON ip.id = irl.product_id
    WHERE irl.receipt_id = v_receipt_id
      AND ip.inventory_item_id IS NOT NULL
    GROUP BY ip.inventory_item_id
  ) received
  WHERE ii.id = received.inventory_item_id
    AND ii.restaurant_id = v_order.restaurant_id;

  INSERT INTO public.inventory_transactions (
    restaurant_id,
    ingredient_id,
    transaction_type,
    quantity_g,
    reference_type,
    reference_id,
    note,
    created_by
  )
  SELECT
    v_order.restaurant_id,
    ip.inventory_item_id,
    'restock',
    SUM(irl.accepted_quantity_base),
    'inventory_purchase_receipt',
    v_receipt_id,
    COALESCE(NULLIF(btrim(COALESCE(p_memo, '')), ''), 'Inventory purchase receipt'),
    auth.uid()
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_products ip
    ON ip.id = irl.product_id
  WHERE irl.receipt_id = v_receipt_id
    AND ip.inventory_item_id IS NOT NULL
    AND irl.accepted_quantity_base > 0
  GROUP BY ip.inventory_item_id;

  SELECT COALESCE(SUM(irl.accepted_quantity_base), 0)
  INTO v_accepted_total_after
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_receipts ir
    ON ir.id = irl.receipt_id
   AND ir.status = 'confirmed'
  WHERE ir.purchase_order_id = p_purchase_order_id;

  UPDATE public.inventory_purchase_orders
  SET status = CASE
        WHEN v_accepted_total_after >= v_ordered_total THEN 'received'
        ELSE 'partially_received'
      END,
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  INSERT INTO public.inventory_receipt_confirmation_attempts (
    purchase_order_id,
    receipt_id,
    restaurant_id,
    actor_id,
    attempt_key,
    attempt_status,
    requested_line_count,
    accepted_total_quantity_base,
    rejected_total_quantity_base,
    remaining_quantity_before_base,
    remaining_quantity_after_base,
    metadata
  )
  VALUES (
    p_purchase_order_id,
    v_receipt_id,
    v_order.restaurant_id,
    auth.uid(),
    v_attempt_key_normalized,
    'succeeded',
    v_requested_line_count,
    v_accepted_total_this_receipt,
    v_rejected_total_this_receipt,
    GREATEST(v_ordered_total - v_accepted_total_before, 0),
    GREATEST(v_ordered_total - v_accepted_total_after, 0),
    jsonb_build_object(
      'order_status_after', v_order.status,
      'ordered_total_base', v_ordered_total,
      'accepted_total_after_base', v_accepted_total_after
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
    'inventory_receipt_confirmed',
    'inventory_purchase_order',
    p_purchase_order_id,
    jsonb_build_object(
      'receipt_id', v_receipt_id,
      'attempt_key', v_attempt_key_normalized,
      'requested_line_count', v_requested_line_count,
      'accepted_total_quantity_base', v_accepted_total_this_receipt,
      'rejected_total_quantity_base', v_rejected_total_this_receipt,
      'remaining_quantity_after_base', GREATEST(v_ordered_total - v_accepted_total_after, 0),
      'order_status_after', v_order.status
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_inventory_receipt_attempt_trace(
  p_purchase_order_id UUID,
  p_limit INTEGER DEFAULT 20
) RETURNS TABLE (
  attempt_id UUID,
  purchase_order_id UUID,
  receipt_id UUID,
  attempt_key TEXT,
  attempt_status TEXT,
  requested_line_count INTEGER,
  accepted_total_quantity_base NUMERIC,
  rejected_total_quantity_base NUMERIC,
  remaining_quantity_before_base NUMERIC,
  remaining_quantity_after_base NUMERIC,
  created_at TIMESTAMPTZ,
  metadata JSONB
) AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    attempt.id,
    attempt.purchase_order_id,
    attempt.receipt_id,
    attempt.attempt_key,
    attempt.attempt_status,
    attempt.requested_line_count,
    attempt.accepted_total_quantity_base,
    attempt.rejected_total_quantity_base,
    attempt.remaining_quantity_before_base,
    attempt.remaining_quantity_after_base,
    attempt.created_at,
    attempt.metadata
  FROM public.inventory_receipt_confirmation_attempts attempt
  WHERE attempt.purchase_order_id = p_purchase_order_id
  ORDER BY attempt.created_at DESC
  LIMIT GREATEST(COALESCE(p_limit, 20), 1);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_inventory_receiving_operational_observability(
  p_store_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_store_id UUID;
  v_open_po_count INTEGER := 0;
  v_overdue_open_po_count INTEGER := 0;
  v_receivable_po_count INTEGER := 0;
  v_office_handoff_po_count INTEGER := 0;
  v_latest_attempts JSONB := '[]'::JSONB;
BEGIN
  IF p_store_id IS NULL THEN
    v_store_id := public.get_user_store_id();
  ELSE
    v_store_id := p_store_id;
  END IF;

  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_STORE_REQUIRED';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  SELECT COUNT(*)
  INTO v_open_po_count
  FROM public.inventory_purchase_orders po
  WHERE po.restaurant_id = v_store_id
    AND po.status NOT IN ('received', 'cancelled');

  SELECT COUNT(*)
  INTO v_overdue_open_po_count
  FROM public.inventory_purchase_orders po
  WHERE po.restaurant_id = v_store_id
    AND po.status NOT IN ('received', 'cancelled')
    AND po.requested_delivery_date IS NOT NULL
    AND po.requested_delivery_date < CURRENT_DATE;

  SELECT COUNT(*)
  INTO v_receivable_po_count
  FROM public.inventory_purchase_orders po
  WHERE po.restaurant_id = v_store_id
    AND po.status IN ('office_approved', 'ordered', 'partially_received');

  SELECT COUNT(*)
  INTO v_office_handoff_po_count
  FROM public.inventory_purchase_orders po
  WHERE po.restaurant_id = v_store_id
    AND po.status IN ('submitted', 'office_returned');

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'attempt_id', attempt.id,
        'purchase_order_id', attempt.purchase_order_id,
        'receipt_id', attempt.receipt_id,
        'attempt_key', attempt.attempt_key,
        'attempt_status', attempt.attempt_status,
        'requested_line_count', attempt.requested_line_count,
        'accepted_total_quantity_base', attempt.accepted_total_quantity_base,
        'rejected_total_quantity_base', attempt.rejected_total_quantity_base,
        'remaining_quantity_before_base', attempt.remaining_quantity_before_base,
        'remaining_quantity_after_base', attempt.remaining_quantity_after_base,
        'created_at', attempt.created_at,
        'metadata', attempt.metadata
      )
      ORDER BY attempt.created_at DESC
    ),
    '[]'::JSONB
  )
  INTO v_latest_attempts
  FROM (
    SELECT *
    FROM public.inventory_receipt_confirmation_attempts
    WHERE restaurant_id = v_store_id
    ORDER BY created_at DESC
    LIMIT 30
  ) attempt;

  RETURN jsonb_build_object(
    'store_id', v_store_id,
    'open_purchase_order_count', v_open_po_count,
    'overdue_open_purchase_order_count', v_overdue_open_po_count,
    'receivable_purchase_order_count', v_receivable_po_count,
    'office_handoff_purchase_order_count', v_office_handoff_po_count,
    'latest_receipt_attempts', v_latest_attempts
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.confirm_inventory_purchase_receipt(UUID, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_inventory_receipt_attempt_trace(UUID, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_inventory_receiving_operational_observability(UUID) TO authenticated;
