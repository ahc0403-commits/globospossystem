-- ============================================================
-- Contract phase: rename daily closing/admin audit RPC inputs to store naming
-- 2026-04-14
-- Scope:
-- - create_daily_closing
-- - get_daily_closings
-- - get_admin_mutation_audit_trace
-- - get_admin_today_summary
-- Notes:
-- - physical schema still uses restaurant_id during coexistence
-- - audit trace accepts both store_id and legacy restaurant_id payload keys
-- ============================================================

DROP FUNCTION IF EXISTS public.create_daily_closing(uuid, text);
DROP FUNCTION IF EXISTS public.get_daily_closings(uuid, int);
DROP FUNCTION IF EXISTS public.get_admin_mutation_audit_trace(uuid, int);
DROP FUNCTION IF EXISTS public.get_admin_today_summary(uuid);

CREATE OR REPLACE FUNCTION public.create_daily_closing(
  p_store_id UUID,
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
  IF p_store_id IS NULL THEN
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
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'DAILY_CLOSING_FORBIDDEN';
  END IF;

  v_closing_date := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE;
  v_day_start := v_closing_date::TIMESTAMPTZ;

  SELECT id INTO v_existing_id
  FROM daily_closings
  WHERE restaurant_id = p_store_id
    AND closing_date = v_closing_date;

  IF FOUND THEN
    RAISE EXCEPTION 'DAILY_CLOSING_ALREADY_EXISTS';
  END IF;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_orders_total, v_orders_completed, v_orders_cancelled
  FROM public.orders
  WHERE restaurant_id = p_store_id
    AND created_at >= v_day_start;

  SELECT COALESCE(COUNT(*), 0)
  INTO v_items_cancelled
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.restaurant_id = p_store_id
    AND oi.status = 'cancelled'
    AND o.created_at >= v_day_start;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'card' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) NOT IN ('cash', 'card') THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay
  FROM public.payments
  WHERE restaurant_id = p_store_id
    AND is_revenue = TRUE
    AND created_at >= v_day_start;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0)
  INTO v_service_count, v_service_total
  FROM public.payments
  WHERE restaurant_id = p_store_id
    AND is_revenue = FALSE
    AND created_at >= v_day_start;

  SELECT COALESCE(COUNT(*), 0)
  INTO v_low_stock_count
  FROM public.inventory_items
  WHERE restaurant_id = p_store_id
    AND is_active = TRUE
    AND reorder_point IS NOT NULL
    AND current_stock <= reorder_point;

  INSERT INTO daily_closings (
    restaurant_id, closing_date, closed_by,
    orders_total, orders_completed, orders_cancelled, items_cancelled,
    payments_count, payments_total, payments_cash, payments_card, payments_pay,
    service_count, service_total, low_stock_count, notes
  ) VALUES (
    p_store_id, v_closing_date, auth.uid(),
    v_orders_total, v_orders_completed, v_orders_cancelled, v_items_cancelled,
    v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay,
    v_service_count, v_service_total, v_low_stock_count, p_notes
  ) RETURNING id INTO v_new_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_daily_closing',
    'daily_closings',
    v_new_id,
    jsonb_build_object(
      'store_id', p_store_id,
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

CREATE OR REPLACE FUNCTION public.get_daily_closings(
  p_store_id UUID,
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
  low_stock_count INT,
  notes TEXT,
  created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 30), 1), 90);
BEGIN
  IF p_store_id IS NULL THEN
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
     AND v_actor.restaurant_id <> p_store_id THEN
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
    dc.low_stock_count,
    dc.notes,
    dc.created_at
  FROM daily_closings dc
  LEFT JOIN public.users u ON u.auth_id = dc.closed_by
  WHERE dc.restaurant_id = p_store_id
  ORDER BY dc.closing_date DESC
  LIMIT v_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_admin_mutation_audit_trace(
  p_store_id UUID,
  p_limit INT DEFAULT 10
) RETURNS TABLE (
  audit_log_id UUID,
  created_at TIMESTAMPTZ,
  action TEXT,
  entity_type TEXT,
  entity_id UUID,
  actor_id UUID,
  actor_name TEXT,
  changed_fields JSONB,
  old_values JSONB,
  new_values JSONB
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_limit INT := LEAST(GREATEST(COALESCE(p_limit, 10), 1), 50);
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'AUDIT_TRACE_RESTAURANT_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'AUDIT_TRACE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'AUDIT_TRACE_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    al.id AS audit_log_id,
    al.created_at,
    al.action,
    al.entity_type,
    al.entity_id,
    al.actor_id,
    COALESCE(u.full_name, '알 수 없음') AS actor_name,
    COALESCE(al.details -> 'changed_fields', '[]'::jsonb) AS changed_fields,
    COALESCE(al.details -> 'old_values', '{}'::jsonb) AS old_values,
    COALESCE(al.details -> 'new_values', '{}'::jsonb) AS new_values
  FROM public.audit_logs al
  LEFT JOIN public.users u
    ON u.auth_id = al.actor_id
  WHERE al.entity_type = ANY (
      ARRAY['restaurants', 'tables', 'menu_categories', 'menu_items']
    )
    AND (
      NULLIF(COALESCE(al.details ->> 'store_id', al.details ->> 'restaurant_id'), '')::UUID = p_store_id
      OR (
        al.entity_type = 'restaurants'
        AND al.entity_id = p_store_id
      )
    )
    AND al.action = ANY (
      ARRAY[
        'admin_create_restaurant',
        'admin_update_restaurant',
        'admin_deactivate_restaurant',
        'admin_update_restaurant_settings',
        'admin_create_table',
        'admin_update_table',
        'admin_delete_table',
        'admin_create_menu_category',
        'admin_update_menu_category',
        'admin_delete_menu_category',
        'admin_create_menu_item',
        'admin_update_menu_item',
        'admin_delete_menu_item'
      ]
    )
  ORDER BY al.created_at DESC
  LIMIT v_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_admin_today_summary(
  p_store_id UUID
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
  IF p_store_id IS NULL THEN
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
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'TODAY_SUMMARY_FORBIDDEN';
  END IF;

  v_today_start := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::DATE::TIMESTAMPTZ;

  SELECT
    COALESCE(SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'confirmed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'serving' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0)
  INTO v_orders_pending, v_orders_confirmed, v_orders_serving,
       v_orders_completed, v_orders_cancelled
  FROM public.orders
  WHERE restaurant_id = p_store_id
    AND created_at >= v_today_start;

  SELECT COALESCE(COUNT(*), 0)
  INTO v_items_cancelled
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE o.restaurant_id = p_store_id
    AND oi.status = 'cancelled'
    AND o.created_at >= v_today_start;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) = 'cash' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN LOWER(method) <> 'cash' THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card
  FROM public.payments
  WHERE restaurant_id = p_store_id
    AND is_revenue = TRUE
    AND created_at >= v_today_start;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(CASE WHEN status = 'occupied' THEN 1 ELSE 0 END), 0)
  INTO v_tables_total, v_tables_occupied
  FROM public.tables
  WHERE restaurant_id = p_store_id;

  SELECT COALESCE(COUNT(*), 0)
  INTO v_low_stock_count
  FROM public.inventory_items
  WHERE restaurant_id = p_store_id
    AND is_active = TRUE
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
