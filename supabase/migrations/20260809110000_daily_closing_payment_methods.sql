-- Keep card, electronic pay, and bank transfer as separate daily-closing
-- report buckets. Existing closing snapshots predate the bank-transfer bucket,
-- so the payment-method breakdown is read from the immutable payment ledger.
-- production-gate: self-verifying

BEGIN;

DROP FUNCTION IF EXISTS public.get_daily_closing_days(uuid, int);
CREATE FUNCTION public.get_daily_closing_days(
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
  payments_bank_transfer numeric,
  opening_cash_amount numeric,
  expected_cash_amount numeric,
  counted_cash_amount numeric,
  cash_variance numeric,
  service_count int,
  service_total numeric,
  low_stock_count int,
  notes text,
  created_at timestamptz,
  close_source text
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
  WITH business_days AS (
    SELECT (
      (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date - day_offset
    )::date AS business_date
    FROM generate_series(0, v_limit - 1) AS days(day_offset)
  ), live_orders AS (
    SELECT
      (o.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS business_date,
      count(*)::int AS orders_total,
      count(*) FILTER (WHERE o.status = 'completed')::int AS orders_completed,
      count(*) FILTER (WHERE o.status = 'cancelled')::int AS orders_cancelled
    FROM public.orders o
    JOIN business_days d ON d.business_date =
      (o.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    WHERE o.restaurant_id = p_store_id
    GROUP BY 1
  ), live_cancelled_items AS (
    SELECT
      (o.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS business_date,
      count(*)::int AS items_cancelled
    FROM public.order_items oi
    JOIN public.orders o ON o.id = oi.order_id
    JOIN business_days d ON d.business_date =
      (o.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    WHERE o.restaurant_id = p_store_id AND oi.status = 'cancelled'
    GROUP BY 1
  ), live_payments AS (
    SELECT
      (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS business_date,
      count(*) FILTER (WHERE p.is_revenue)::int AS payments_count,
      COALESCE(sum(COALESCE(p.amount_portion, p.amount)) FILTER (
        WHERE p.is_revenue
      ), 0) AS payments_total,
      COALESCE(sum(COALESCE(p.amount_portion, p.amount)) FILTER (
        WHERE p.is_revenue AND lower(p.method) = 'cash'
      ), 0) AS payments_cash,
      COALESCE(sum(COALESCE(p.amount_portion, p.amount)) FILTER (
        WHERE p.is_revenue
          AND lower(p.method) IN ('card', 'creditcard', 'atm')
      ), 0) AS payments_card,
      COALESCE(sum(COALESCE(p.amount_portion, p.amount)) FILTER (
        WHERE p.is_revenue
          AND lower(p.method) NOT IN (
            'cash', 'card', 'creditcard', 'atm', 'banktransfer'
          )
      ), 0) AS payments_pay,
      COALESCE(sum(COALESCE(p.amount_portion, p.amount)) FILTER (
        WHERE p.is_revenue AND lower(p.method) = 'banktransfer'
      ), 0) AS payments_bank_transfer,
      count(*) FILTER (WHERE NOT p.is_revenue)::int AS service_count,
      COALESCE(sum(COALESCE(p.amount_portion, p.amount)) FILTER (
        WHERE NOT p.is_revenue
      ), 0) AS service_total
    FROM public.payments p
    JOIN business_days d ON d.business_date =
      (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    WHERE p.restaurant_id = p_store_id
    GROUP BY 1
  )
  SELECT
    dc.id,
    d.business_date,
    COALESCE(u.full_name, CASE
      WHEN dc.close_source = 'scheduled' THEN 'Scheduled'
      ELSE ''
    END),
    COALESCE(dc.orders_total, lo.orders_total, 0),
    COALESCE(dc.orders_completed, lo.orders_completed, 0),
    COALESCE(dc.orders_cancelled, lo.orders_cancelled, 0),
    COALESCE(dc.items_cancelled, li.items_cancelled, 0),
    COALESCE(dc.payments_count, lp.payments_count, 0),
    COALESCE(dc.payments_total, lp.payments_total, 0),
    COALESCE(dc.payments_cash, lp.payments_cash, 0),
    COALESCE(lp.payments_card, dc.payments_card, 0),
    COALESCE(lp.payments_pay, dc.payments_pay, 0),
    COALESCE(lp.payments_bank_transfer, 0),
    COALESCE(dc.opening_cash_amount, 0),
    COALESCE(dc.expected_cash_amount, 0),
    COALESCE(dc.counted_cash_amount, 0),
    COALESCE(dc.cash_variance, 0),
    COALESCE(dc.service_count, lp.service_count, 0),
    COALESCE(dc.service_total, lp.service_total, 0),
    COALESCE(dc.low_stock_count, 0),
    dc.notes,
    dc.created_at,
    dc.close_source
  FROM business_days d
  LEFT JOIN public.daily_closings dc
    ON dc.restaurant_id = p_store_id AND dc.closing_date = d.business_date
  LEFT JOIN public.users u ON u.auth_id = dc.closed_by
  LEFT JOIN live_orders lo ON lo.business_date = d.business_date
  LEFT JOIN live_cancelled_items li ON li.business_date = d.business_date
  LEFT JOIN live_payments lp ON lp.business_date = d.business_date
  ORDER BY d.business_date DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.get_daily_closing_days(uuid, int)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_daily_closing_days(uuid, int)
  TO authenticated, service_role;

DO $$
DECLARE
  v_result text;
BEGIN
  IF to_regprocedure('public.get_daily_closing_days(uuid,integer)') IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSING_PAYMENT_METHODS_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_function_result(
    'public.get_daily_closing_days(uuid,integer)'::regprocedure
  ) INTO v_result;

  IF position('payments_bank_transfer numeric' IN lower(v_result)) = 0 THEN
    RAISE EXCEPTION 'DAILY_CLOSING_BANK_TRANSFER_RESULT_MISSING';
  END IF;
END;
$$;

COMMIT;
