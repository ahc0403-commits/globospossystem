-- ============================================================
-- Bundle G-5: Daily Closing Snapshot
-- 2026-04-10
-- Scope:
--   1. New daily_closings table to persist end-of-day operational snapshots
--   2. New RPC create_daily_closing — admin/super_admin only, computes
--      today's metrics server-side and inserts; blocks duplicate per date
--   3. New RPC get_daily_closings — admin/super_admin read-only history
-- Boundaries:
--   - No shift accounting, no reconciliation, no refund/split-payment
--   - All metrics derived from existing orders/order_items/payments tables
--   - No lock-after-close behavior
--   - No cashier write access
-- ============================================================

BEGIN;

-- ============================================================
-- STEP 1: daily_closings table
-- ============================================================

CREATE TABLE IF NOT EXISTS daily_closings (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id   UUID NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
  closing_date    DATE NOT NULL,
  closed_by       UUID NOT NULL REFERENCES auth.users(id),

  -- Order metrics
  orders_total      INT NOT NULL DEFAULT 0,
  orders_completed  INT NOT NULL DEFAULT 0,
  orders_cancelled  INT NOT NULL DEFAULT 0,
  items_cancelled   INT NOT NULL DEFAULT 0,

  -- Payment metrics (revenue)
  payments_count  INT NOT NULL DEFAULT 0,
  payments_total  DECIMAL(12,2) NOT NULL DEFAULT 0,
  payments_cash   DECIMAL(12,2) NOT NULL DEFAULT 0,
  payments_card   DECIMAL(12,2) NOT NULL DEFAULT 0,
  payments_pay    DECIMAL(12,2) NOT NULL DEFAULT 0,

  -- Service payments (non-revenue)
  service_count   INT NOT NULL DEFAULT 0,
  service_total   DECIMAL(12,2) NOT NULL DEFAULT 0,

  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT unique_daily_closing UNIQUE (restaurant_id, closing_date)
);

CREATE INDEX IF NOT EXISTS idx_daily_closings_restaurant_date
  ON daily_closings(restaurant_id, closing_date DESC);

-- RLS: no direct client access — all access via SECURITY DEFINER RPCs
ALTER TABLE daily_closings ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- STEP 2: create_daily_closing RPC
-- ============================================================

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

  -- Insert closing record
  INSERT INTO daily_closings (
    restaurant_id, closing_date, closed_by,
    orders_total, orders_completed, orders_cancelled, items_cancelled,
    payments_count, payments_total, payments_cash, payments_card, payments_pay,
    service_count, service_total, notes
  ) VALUES (
    p_restaurant_id, v_closing_date, auth.uid(),
    v_orders_total, v_orders_completed, v_orders_cancelled, v_items_cancelled,
    v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay,
    v_service_count, v_service_total, p_notes
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
      'payments_total', v_payments_total
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
    'service_total', v_service_total
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;


-- ============================================================
-- STEP 3: get_daily_closings RPC
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_daily_closings(
  p_restaurant_id UUID,
  p_limit INT DEFAULT 30
) RETURNS TABLE (
  closing_id UUID,
  closing_date DATE,
  closed_by_name TEXT,
  orders_total INT,
  orders_completed INT,
  orders_cancelled INT,
  items_cancelled INT,
  payments_count INT,
  payments_total NUMERIC,
  payments_cash NUMERIC,
  payments_card NUMERIC,
  payments_pay NUMERIC,
  service_count INT,
  service_total NUMERIC,
  notes TEXT,
  created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 90);
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'DAILY_CLOSINGS_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    dc.id AS closing_id,
    dc.closing_date,
    COALESCE(u.full_name, '알 수 없음') AS closed_by_name,
    dc.orders_total,
    dc.orders_completed,
    dc.orders_cancelled,
    dc.items_cancelled,
    dc.payments_count,
    dc.payments_total,
    dc.payments_cash,
    dc.payments_card,
    dc.payments_pay,
    dc.service_count,
    dc.service_total,
    dc.notes,
    dc.created_at
  FROM daily_closings dc
  LEFT JOIN public.users u ON u.auth_id = dc.closed_by
  WHERE dc.restaurant_id = p_restaurant_id
  ORDER BY dc.closing_date DESC
  LIMIT v_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

COMMIT;
