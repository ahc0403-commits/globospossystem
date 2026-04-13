-- ============================================================
-- Bundle G-2: Admin Operational Visibility Strengthening
-- 2026-04-09
-- Scope:
-- Step 1: Expand get_admin_mutation_audit_trace to include order lifecycle actions
-- Step 2: New RPC get_admin_today_summary — read-only today operational metrics
-- Boundaries: no new write paths, no accounting changes, no refund/split-payment
-- ============================================================

-- ============================================================
-- Step 1: Expand audit trace to include order lifecycle actions
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_admin_mutation_audit_trace(
  p_restaurant_id UUID,
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
  IF p_restaurant_id IS NULL THEN
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
     AND v_actor.restaurant_id <> p_restaurant_id THEN
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
      ARRAY[
        'restaurants', 'tables', 'menu_categories', 'menu_items',
        'orders', 'order_items', 'payments'
      ]
    )
    AND (
      NULLIF(al.details ->> 'restaurant_id', '')::UUID = p_restaurant_id
      OR (
        al.entity_type = 'restaurants'
        AND al.entity_id = p_restaurant_id
      )
    )
    AND al.action = ANY (
      ARRAY[
        -- admin mutations (existing)
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
        'admin_delete_menu_item',
        -- order lifecycle (new)
        'create_order',
        'create_buffet_order',
        'add_items_to_order',
        'cancel_order',
        'cancel_order_item',
        'edit_order_item_quantity',
        'transfer_order_table',
        'process_payment',
        'update_order_item_status'
      ]
    )
  ORDER BY al.created_at DESC
  LIMIT v_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;


-- ============================================================
-- Step 2: Read-only today summary RPC
-- ============================================================

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
    'tables_occupied', v_tables_occupied
  );

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
