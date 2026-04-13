-- ============================================================
-- Fix: remove non-existent is_active column reference on
--      inventory_items inside create_daily_closing and
--      get_admin_today_summary.
--
-- Root cause: 20260410000003_inventory_low_stock_visibility.sql
-- added `AND is_active = TRUE` to the low-stock COUNT query that
-- targets public.inventory_items, but that table has never had an
-- is_active column (initial schema + inventory_v2 only add
-- current_stock and reorder_point).  At runtime, every call to
-- create_daily_closing and get_admin_today_summary raised:
--   ERROR: column "is_active" does not exist
-- which propagated as a non-PostgrestException in the Flutter
-- client, preventing the _closingSucceeded flag from being set.
--
-- Fix: drop the invalid `AND is_active = TRUE` predicate from the
-- inventory_items filter in both RPCs.  No other logic is changed.
-- ============================================================

-- ---------------------------------------------------------------
-- 1. create_daily_closing — remove is_active from low-stock query
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_daily_closing(
  p_restaurant_id UUID,
  p_notes TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_closing_date DATE;
  v_existing_id UUID;
  v_orders_total INT;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_items_cancelled INT;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_payments_pay NUMERIC;
  v_service_count INT;
  v_service_total NUMERIC;
  v_low_stock_count INT;
  v_day_start TIMESTAMPTZ;
  v_new_id UUID;
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSING_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'DAILY_CLOSING_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'DAILY_CLOSING_FORBIDDEN';
  END IF;

  -- Vietnam timezone for closing date
  v_closing_date := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE;
  v_day_start := v_closing_date::TIMESTAMPTZ;

  -- Check duplicate
  SELECT id INTO v_existing_id
  FROM daily_closings
  WHERE restaurant_id = p_restaurant_id
    AND closing_date = v_closing_date;

  IF FOUND THEN
    RAISE EXCEPTION 'DAILY_CLOSING_ALREADY_EXISTS';
  END IF;

  -- Compute order metrics
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_orders_total, v_orders_completed, v_orders_cancelled
  FROM public.orders
  WHERE restaurant_id = p_restaurant_id
    AND created_at >= v_day_start;

  -- Cancelled items
  SELECT COALESCE(COUNT(*), 0)
  INTO v_items_cancelled
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.restaurant_id = p_restaurant_id
    AND oi.status = 'cancelled'
    AND o.created_at >= v_day_start;

  -- Revenue payments
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
    AND created_at >= v_day_start;

  -- Service payments
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0)
  INTO v_service_count, v_service_total
  FROM public.payments
  WHERE restaurant_id = p_restaurant_id
    AND is_revenue = FALSE
    AND created_at >= v_day_start;

  -- Low-stock count (snapshot at closing time).
  -- NOTE: inventory_items has no is_active column; filter only on
  -- reorder_point and current_stock which exist since inventory_v2.
  SELECT COALESCE(COUNT(*), 0)
  INTO v_low_stock_count
  FROM public.inventory_items
  WHERE restaurant_id = p_restaurant_id
    AND reorder_point IS NOT NULL
    AND current_stock <= reorder_point;

  -- Insert closing record
  INSERT INTO daily_closings (
    restaurant_id, closing_date, closed_by,
    orders_total, orders_completed, orders_cancelled, items_cancelled,
    payments_count, payments_total, payments_cash, payments_card, payments_pay,
    service_count, service_total, low_stock_count, notes
  ) VALUES (
    p_restaurant_id, v_closing_date, auth.uid(),
    v_orders_total, v_orders_completed, v_orders_cancelled, v_items_cancelled,
    v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay,
    v_service_count, v_service_total, v_low_stock_count, p_notes
  ) RETURNING id INTO v_new_id;

  -- Audit log
  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_daily_closing',
    'daily_closings',
    v_new_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'closing_date', v_closing_date,
      'orders_total', v_orders_total,
      'payments_total', v_payments_total,
      'low_stock_count', v_low_stock_count
    )
  );

  RETURN jsonb_build_object(
    'id', v_new_id,
    'closing_date', v_closing_date,
    'orders_total', v_orders_total,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'items_cancelled', v_items_cancelled,
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'payments_pay', v_payments_pay,
    'service_count', v_service_count,
    'service_total', v_service_total,
    'low_stock_count', v_low_stock_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;


-- ---------------------------------------------------------------
-- 2. get_admin_today_summary — remove is_active from low-stock query
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_admin_today_summary(
  p_restaurant_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_today_start TIMESTAMPTZ;
  v_result JSONB;
  v_orders_pending INT;
  v_orders_confirmed INT;
  v_orders_serving INT;
  v_orders_completed INT;
  v_orders_cancelled INT;
  v_items_cancelled INT;
  v_payments_count INT;
  v_payments_total NUMERIC;
  v_payments_cash NUMERIC;
  v_payments_card NUMERIC;
  v_tables_total INT;
  v_tables_occupied INT;
  v_low_stock_count INT;
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_FORBIDDEN';
  END IF;

  -- Use Vietnam timezone for "today"
  v_today_start := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE::TIMESTAMPTZ;

  -- Order counts by status
  SELECT
    COALESCE(SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'confirmed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'serving' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_orders_pending, v_orders_confirmed, v_orders_serving,
       v_orders_completed, v_orders_cancelled
  FROM public.orders
  WHERE restaurant_id = p_restaurant_id
    AND created_at >= v_today_start;

  -- Cancelled order items today
  SELECT COALESCE(COUNT(*), 0)
  INTO v_items_cancelled
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.restaurant_id = p_restaurant_id
    AND oi.status = 'cancelled'
    AND o.created_at >= v_today_start;

  -- Payment counts and totals (revenue only)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) <> 'cash' THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card
  FROM public.payments
  WHERE restaurant_id = p_restaurant_id
    AND is_revenue = TRUE
    AND created_at >= v_today_start;

  -- Table occupancy snapshot (live, not time-filtered)
  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'occupied' THEN 1 ELSE 0 END), 0)
  INTO v_tables_total, v_tables_occupied
  FROM public.tables
  WHERE restaurant_id = p_restaurant_id;

  -- Live low-stock count.
  -- NOTE: inventory_items has no is_active column; filter only on
  -- reorder_point and current_stock which exist since inventory_v2.
  SELECT COALESCE(COUNT(*), 0)
  INTO v_low_stock_count
  FROM public.inventory_items
  WHERE restaurant_id = p_restaurant_id
    AND reorder_point IS NOT NULL
    AND current_stock <= reorder_point;

  v_result := jsonb_build_object(
    'orders_pending', v_orders_pending,
    'orders_confirmed', v_orders_confirmed,
    'orders_serving', v_orders_serving,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'orders_total', v_orders_pending + v_orders_confirmed + v_orders_serving + v_orders_completed + v_orders_cancelled,
    'items_cancelled', v_items_cancelled,
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'tables_total', v_tables_total,
    'tables_occupied', v_tables_occupied,
    'low_stock_count', v_low_stock_count
  );

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
