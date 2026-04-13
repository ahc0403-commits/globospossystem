-- ============================================================
-- Bundle G-3: Cashier Shift Close + Waiter Status
-- 2026-04-09
-- Scope:
-- Step 1: New RPC get_cashier_today_summary — read-only today payment/order summary
--         accessible by cashier/admin/super_admin
-- Boundaries: no new write paths, no shift table, no accounting changes
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_cashier_today_summary(
  p_restaurant_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_today_start TIMESTAMPTZ;
  v_result JSONB;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_payments_pay NUMERIC;
  v_service_count INT;
  v_service_total NUMERIC;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_orders_active INT;
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_FORBIDDEN';
  END IF;

  IF v_actor.role NOT IN ('admin', 'super_admin')
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_FORBIDDEN';
  END IF;

  -- Use Vietnam timezone for "today"
  v_today_start := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE::TIMESTAMPTZ;

  -- Revenue payments (is_revenue = true)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'card' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) NOT IN ('cash', 'card') THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay
  FROM public.payments
  WHERE restaurant_id = p_restaurant_id
    AND is_revenue = TRUE
    AND created_at >= v_today_start;

  -- Service payments (is_revenue = false)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0)
  INTO v_service_count, v_service_total
  FROM public.payments
  WHERE restaurant_id = p_restaurant_id
    AND is_revenue = FALSE
    AND created_at >= v_today_start;

  -- Order status counts for today
  SELECT
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status NOT IN ('completed', 'cancelled') THEN 1 ELSE 0 END), 0)
  INTO v_orders_completed, v_orders_cancelled, v_orders_active
  FROM public.orders
  WHERE restaurant_id = p_restaurant_id
    AND created_at >= v_today_start;

  v_result := jsonb_build_object(
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'payments_pay', v_payments_pay,
    'service_count', v_service_count,
    'service_total', v_service_total,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'orders_active', v_orders_active
  );

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
