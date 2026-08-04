-- Atomic combined-table checkout for cashier operations.
-- Each source order keeps its own payment, inventory, discount, and invoice
-- lifecycle while the customer-facing tender is grouped for auditability.

CREATE TABLE IF NOT EXISTS public.combined_payment_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  method text NOT NULL,
  total_amount numeric(15,2) NOT NULL CHECK (total_amount > 0),
  order_count integer NOT NULL CHECK (order_count >= 2),
  status text NOT NULL DEFAULT 'processing'
    CHECK (status IN ('processing', 'completed')),
  processed_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS combined_payment_group_id uuid
  REFERENCES public.combined_payment_groups(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_combined_payment_groups_store_created
  ON public.combined_payment_groups(restaurant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_payments_combined_payment_group
  ON public.payments(combined_payment_group_id)
  WHERE combined_payment_group_id IS NOT NULL;

ALTER TABLE public.combined_payment_groups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS combined_payment_groups_store_select
  ON public.combined_payment_groups;
CREATE POLICY combined_payment_groups_store_select
  ON public.combined_payment_groups
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

CREATE OR REPLACE FUNCTION public.process_combined_table_payment(
  p_store_id uuid,
  p_order_amounts jsonb,
  p_method text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_group public.combined_payment_groups%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_entry record;
  v_order_count integer;
  v_distinct_count integer;
  v_total numeric(15,2);
  v_payments jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'COMBINED_PAYMENT_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'COMBINED_PAYMENT_STORE_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'COMBINED_PAYMENT_FORBIDDEN';
  END IF;

  IF p_order_amounts IS NULL
     OR jsonb_typeof(p_order_amounts) <> 'array' THEN
    RAISE EXCEPTION 'COMBINED_PAYMENT_ORDERS_REQUIRED';
  END IF;

  SELECT
    count(*),
    count(DISTINCT order_id),
    round(sum(amount), 2)
  INTO v_order_count, v_distinct_count, v_total
  FROM (
    SELECT
      nullif(entry->>'order_id', '')::uuid AS order_id,
      round((entry->>'amount')::numeric, 2) AS amount
    FROM jsonb_array_elements(p_order_amounts) entry
  ) requested;

  IF v_order_count < 2 OR v_order_count > 20 THEN
    RAISE EXCEPTION 'COMBINED_PAYMENT_ORDER_COUNT_INVALID';
  END IF;

  IF v_distinct_count <> v_order_count THEN
    RAISE EXCEPTION 'COMBINED_PAYMENT_DUPLICATE_ORDER';
  END IF;

  IF v_total IS NULL OR v_total <= 0 THEN
    RAISE EXCEPTION 'COMBINED_PAYMENT_AMOUNT_INVALID';
  END IF;

  IF p_method NOT IN (
    'CASH', 'CREDITCARD', 'ATM', 'MOMO', 'ZALOPAY',
    'VNPAY', 'SHOPEEPAY', 'BANKTRANSFER', 'VOUCHER', 'CREDITSALE', 'OTHER'
  ) THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_order_amounts) entry
    LEFT JOIN public.orders o
      ON o.id = nullif(entry->>'order_id', '')::uuid
     AND o.restaurant_id = p_store_id
    WHERE o.id IS NULL
       OR o.status <> 'serving'
       OR coalesce(o.order_purpose, 'customer') <> 'customer'
       OR round((entry->>'amount')::numeric, 2) <= 0
  ) THEN
    RAISE EXCEPTION 'COMBINED_PAYMENT_ORDER_NOT_PAYABLE';
  END IF;

  -- A deterministic lock order prevents two terminals combining overlapping
  -- table sets from deadlocking each other.
  PERFORM o.id
  FROM public.orders o
  JOIN (
    SELECT nullif(entry->>'order_id', '')::uuid AS order_id
    FROM jsonb_array_elements(p_order_amounts) entry
  ) requested ON requested.order_id = o.id
  WHERE o.restaurant_id = p_store_id
  ORDER BY o.id
  FOR UPDATE;

  INSERT INTO public.combined_payment_groups (
    restaurant_id,
    method,
    total_amount,
    order_count,
    processed_by
  )
  VALUES (
    p_store_id,
    p_method,
    v_total,
    v_order_count,
    auth.uid()
  )
  RETURNING * INTO v_group;

  FOR v_entry IN
    SELECT
      nullif(entry->>'order_id', '')::uuid AS order_id,
      round((entry->>'amount')::numeric, 2) AS amount
    FROM jsonb_array_elements(p_order_amounts) entry
    ORDER BY nullif(entry->>'order_id', '')::uuid
  LOOP
    v_payment := public.process_payment(
      v_entry.order_id,
      p_store_id,
      v_entry.amount,
      p_method
    );

    IF NOT EXISTS (
      SELECT 1
      FROM public.orders o
      WHERE o.id = v_entry.order_id
        AND o.restaurant_id = p_store_id
        AND o.status = 'completed'
    ) THEN
      RAISE EXCEPTION 'COMBINED_PAYMENT_AMOUNT_MISMATCH';
    END IF;

    UPDATE public.payments
    SET combined_payment_group_id = v_group.id
    WHERE id = v_payment.id
    RETURNING * INTO v_payment;

    v_payments := v_payments || jsonb_build_array(to_jsonb(v_payment));
  END LOOP;

  UPDATE public.combined_payment_groups
  SET status = 'completed',
      completed_at = now()
  WHERE id = v_group.id
  RETURNING * INTO v_group;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  VALUES (
    auth.uid(),
    'process_combined_table_payment',
    'combined_payment_groups',
    v_group.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'method', p_method,
      'order_count', v_order_count,
      'total_amount', v_total,
      'order_ids', (
        SELECT jsonb_agg(nullif(entry->>'order_id', '')::uuid)
        FROM jsonb_array_elements(p_order_amounts) entry
      )
    )
  );

  RETURN jsonb_build_object(
    'group_id', v_group.id,
    'store_id', p_store_id,
    'method', p_method,
    'total_amount', v_total,
    'order_count', v_order_count,
    'payments', v_payments
  );
END;
$$;

REVOKE ALL ON FUNCTION public.process_combined_table_payment(uuid, jsonb, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_combined_table_payment(uuid, jsonb, text)
  TO authenticated, service_role;

COMMENT ON TABLE public.combined_payment_groups IS
  'One customer tender covering two or more payable table orders.';
COMMENT ON COLUMN public.payments.combined_payment_group_id IS
  'Optional audit link for payments completed in one combined-table tender.';
