BEGIN;

ALTER TABLE public.daily_closings
  ADD COLUMN IF NOT EXISTS opening_cash_amount numeric(15,2) NOT NULL DEFAULT 0
    CHECK (opening_cash_amount >= 0),
  ADD COLUMN IF NOT EXISTS cash_denominations jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(cash_denominations) = 'object'),
  ADD COLUMN IF NOT EXISTS expected_cash_amount numeric(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS counted_cash_amount numeric(15,2) NOT NULL DEFAULT 0
    CHECK (counted_cash_amount >= 0),
  ADD COLUMN IF NOT EXISTS cash_variance numeric(15,2) NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.get_daily_closing_cash_preview(
  p_store_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_start timestamptz;
  v_end timestamptz;
  v_cash numeric(15,2);
BEGIN
  PERFORM public.require_pos_admin_actor_for_store(
    p_store_id,
    'DAILY_CLOSING_FORBIDDEN'
  );

  v_start := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_end := v_start + interval '1 day';

  SELECT COALESCE(sum(COALESCE(p.amount_portion, p.amount)), 0)
  INTO v_cash
  FROM public.payments p
  WHERE p.restaurant_id = p_store_id
    AND p.is_revenue = true
    AND lower(p.method) = 'cash'
    AND p.created_at >= v_start
    AND p.created_at < v_end;

  RETURN jsonb_build_object(
    'opening_cash_amount', 5000000,
    'payments_cash', v_cash,
    'expected_cash_amount', 5000000 + v_cash
  );
END;
$$;

DROP FUNCTION IF EXISTS public.create_daily_closing(uuid, text);
CREATE FUNCTION public.create_daily_closing(
  p_store_id uuid,
  p_notes text DEFAULT NULL,
  p_cash_denominations jsonb DEFAULT '{}'::jsonb,
  p_opening_cash_amount numeric DEFAULT 5000000
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_closing_date date;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_orders_total int;
  v_orders_completed int;
  v_orders_cancelled int;
  v_items_cancelled int;
  v_payments_count int;
  v_payments_total numeric;
  v_payments_cash numeric;
  v_payments_card numeric;
  v_payments_pay numeric;
  v_service_count int;
  v_service_total numeric;
  v_low_stock_count int;
  v_counted_cash numeric(15,2);
  v_expected_cash numeric(15,2);
  v_cash_variance numeric(15,2);
  v_existing_id uuid;
  v_existing_source text;
  v_new_id uuid;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSING_RESTAURANT_REQUIRED';
  END IF;

  PERFORM public.require_pos_admin_actor_for_store(
    p_store_id,
    'DAILY_CLOSING_FORBIDDEN'
  );

  IF p_opening_cash_amount IS NULL OR p_opening_cash_amount < 0 THEN
    RAISE EXCEPTION 'DAILY_CLOSING_OPENING_CASH_INVALID';
  END IF;

  IF jsonb_typeof(COALESCE(p_cash_denominations, '{}'::jsonb)) <> 'object'
     OR EXISTS (
       SELECT 1
       FROM jsonb_each_text(COALESCE(p_cash_denominations, '{}'::jsonb)) entry
       WHERE entry.key NOT IN (
         '500000', '200000', '100000', '50000', '20000',
         '10000', '5000', '2000', '1000'
       )
          OR entry.value !~ '^[0-9]+$'
          OR entry.value::numeric > 10000
     ) THEN
    RAISE EXCEPTION 'DAILY_CLOSING_DENOMINATIONS_INVALID';
  END IF;

  SELECT COALESCE(sum(entry.key::numeric * entry.value::numeric), 0)
  INTO v_counted_cash
  FROM jsonb_each_text(COALESCE(p_cash_denominations, '{}'::jsonb)) entry;

  v_closing_date := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
  v_day_start := v_closing_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_day_end := (v_closing_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';

  SELECT id, close_source
  INTO v_existing_id, v_existing_source
  FROM public.daily_closings
  WHERE restaurant_id = p_store_id AND closing_date = v_closing_date
  FOR UPDATE;

  IF FOUND AND v_existing_source <> 'scheduled' THEN
    RAISE EXCEPTION 'DAILY_CLOSING_ALREADY_EXISTS';
  END IF;

  SELECT
    count(*),
    count(*) FILTER (WHERE status = 'completed'),
    count(*) FILTER (WHERE status = 'cancelled')
  INTO v_orders_total, v_orders_completed, v_orders_cancelled
  FROM public.orders
  WHERE restaurant_id = p_store_id
    AND created_at >= v_day_start
    AND created_at < v_day_end;

  SELECT count(*)
  INTO v_items_cancelled
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.restaurant_id = p_store_id
    AND oi.status = 'cancelled'
    AND o.created_at >= v_day_start
    AND o.created_at < v_day_end;

  SELECT
    count(*),
    COALESCE(sum(COALESCE(amount_portion, amount)), 0),
    COALESCE(sum(COALESCE(amount_portion, amount)) FILTER (
      WHERE lower(method) = 'cash'
    ), 0),
    COALESCE(sum(COALESCE(amount_portion, amount)) FILTER (
      WHERE lower(method) IN ('card', 'creditcard')
    ), 0),
    COALESCE(sum(COALESCE(amount_portion, amount)) FILTER (
      WHERE lower(method) NOT IN ('cash', 'card', 'creditcard')
    ), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash,
       v_payments_card, v_payments_pay
  FROM public.payments
  WHERE restaurant_id = p_store_id
    AND is_revenue = true
    AND created_at >= v_day_start
    AND created_at < v_day_end;

  SELECT count(*), COALESCE(sum(COALESCE(amount_portion, amount)), 0)
  INTO v_service_count, v_service_total
  FROM public.payments
  WHERE restaurant_id = p_store_id
    AND is_revenue = false
    AND created_at >= v_day_start
    AND created_at < v_day_end;

  SELECT count(*)
  INTO v_low_stock_count
  FROM public.inventory_items
  WHERE restaurant_id = p_store_id
    AND is_active = true
    AND reorder_point IS NOT NULL
    AND current_stock <= reorder_point;

  v_expected_cash := p_opening_cash_amount + v_payments_cash;
  v_cash_variance := v_counted_cash - v_expected_cash;

  IF v_existing_id IS NULL THEN
    INSERT INTO public.daily_closings (
      restaurant_id, closing_date, closed_by, close_source,
      orders_total, orders_completed, orders_cancelled, items_cancelled,
      payments_count, payments_total, payments_cash, payments_card, payments_pay,
      service_count, service_total, low_stock_count, notes,
      opening_cash_amount, cash_denominations, expected_cash_amount,
      counted_cash_amount, cash_variance
    ) VALUES (
      p_store_id, v_closing_date, auth.uid(), 'manual',
      v_orders_total, v_orders_completed, v_orders_cancelled, v_items_cancelled,
      v_payments_count, v_payments_total, v_payments_cash, v_payments_card,
      v_payments_pay, v_service_count, v_service_total, v_low_stock_count, p_notes,
      p_opening_cash_amount, COALESCE(p_cash_denominations, '{}'::jsonb),
      v_expected_cash, v_counted_cash, v_cash_variance
    )
    RETURNING id INTO v_new_id;
  ELSE
    UPDATE public.daily_closings
    SET closed_by = auth.uid(),
        close_source = 'manual',
        orders_total = v_orders_total,
        orders_completed = v_orders_completed,
        orders_cancelled = v_orders_cancelled,
        items_cancelled = v_items_cancelled,
        payments_count = v_payments_count,
        payments_total = v_payments_total,
        payments_cash = v_payments_cash,
        payments_card = v_payments_card,
        payments_pay = v_payments_pay,
        service_count = v_service_count,
        service_total = v_service_total,
        low_stock_count = v_low_stock_count,
        notes = p_notes,
        opening_cash_amount = p_opening_cash_amount,
        cash_denominations = COALESCE(p_cash_denominations, '{}'::jsonb),
        expected_cash_amount = v_expected_cash,
        counted_cash_amount = v_counted_cash,
        cash_variance = v_cash_variance
    WHERE id = v_existing_id
    RETURNING id INTO v_new_id;
  END IF;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    CASE WHEN v_existing_id IS NULL
      THEN 'create_daily_closing'
      ELSE 'reconcile_scheduled_daily_closing'
    END,
    'daily_closings',
    v_new_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'closing_date', v_closing_date,
      'payments_cash', v_payments_cash,
      'opening_cash_amount', p_opening_cash_amount,
      'expected_cash_amount', v_expected_cash,
      'counted_cash_amount', v_counted_cash,
      'cash_variance', v_cash_variance,
      'cash_denominations', COALESCE(p_cash_denominations, '{}'::jsonb)
    )
  );

  RETURN jsonb_build_object(
    'id', v_new_id,
    'closing_date', v_closing_date,
    'payments_cash', v_payments_cash,
    'opening_cash_amount', p_opening_cash_amount,
    'expected_cash_amount', v_expected_cash,
    'counted_cash_amount', v_counted_cash,
    'cash_variance', v_cash_variance
  );
END;
$$;

DROP FUNCTION IF EXISTS public.get_daily_closings(uuid, int);
CREATE FUNCTION public.get_daily_closings(
  p_store_id uuid,
  p_limit int DEFAULT 30
) RETURNS TABLE (
  closing_id uuid,
  closing_date date,
  closed_by_name text,
  orders_total int,
  orders_completed int,
  orders_cancelled int,
  items_cancelled int,
  payments_count int,
  payments_total numeric,
  payments_cash numeric,
  payments_card numeric,
  payments_pay numeric,
  opening_cash_amount numeric,
  expected_cash_amount numeric,
  counted_cash_amount numeric,
  cash_variance numeric,
  service_count int,
  service_total numeric,
  low_stock_count int,
  notes text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_limit int := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 90);
BEGIN
  PERFORM public.require_pos_admin_actor_for_store(
    p_store_id,
    'DAILY_CLOSINGS_FORBIDDEN'
  );

  RETURN QUERY
  SELECT
    dc.id,
    dc.closing_date,
    COALESCE(u.full_name, CASE
      WHEN dc.close_source = 'scheduled' THEN 'Scheduled'
      ELSE 'Unknown'
    END),
    dc.orders_total,
    dc.orders_completed,
    dc.orders_cancelled,
    dc.items_cancelled,
    dc.payments_count,
    dc.payments_total,
    dc.payments_cash,
    dc.payments_card,
    dc.payments_pay,
    dc.opening_cash_amount,
    dc.expected_cash_amount,
    dc.counted_cash_amount,
    dc.cash_variance,
    dc.service_count,
    dc.service_total,
    dc.low_stock_count,
    dc.notes,
    dc.created_at
  FROM public.daily_closings dc
  LEFT JOIN public.users u ON u.auth_id = dc.closed_by
  WHERE dc.restaurant_id = p_store_id
  ORDER BY dc.closing_date DESC
  LIMIT v_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_daily_closing_cash_preview(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_daily_closing_cash_preview(uuid)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_daily_closing(uuid, text, jsonb, numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_daily_closing(uuid, text, jsonb, numeric)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_daily_closings(uuid, int)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_daily_closings(uuid, int)
  TO authenticated, service_role;

COMMIT;
