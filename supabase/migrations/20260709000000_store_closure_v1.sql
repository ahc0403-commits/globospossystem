-- 20260709000000_store_closure_v1.sql
-- Implements STORE_CLOSURE_V1_PLAN_2026_07_08.md.
--
-- Layer 1 (systemic): user_accessible_stores() now excludes inactive stores
--   on BOTH branches, so a deactivated store's staff lose ALL RPC store scope
--   (orders/payments/discounts) — closing the mutation hole (S1). super_admin
--   is unaffected (guards check is_super_admin() first); Office reads via
--   service_role and bypasses RLS.
-- Layer 2 (orchestration): admin_close_store() — open-order guard, deactivate,
--   revoke staff access, refresh claims, printer/queue teardown, and a
--   point-in-time SALES SNAPSHOT into audit_logs for tax-audit preservation.
--   Raw orders/payments/order_items rows are NEVER deleted; super_admin +
--   Office retain read access to closed-store sales indefinitely.
--
-- Pre-apply check (2026-07-08 live): 0 inactive stores, 0 active accesses to
-- inactive stores → Layer 1 is a no-op for current data.
-- Regenerated from live pg_get_functiondef(user_accessible_stores).

BEGIN;

-- ============================================================
-- Layer 1: store-scope guard excludes inactive stores
-- ============================================================
CREATE OR REPLACE FUNCTION public.user_accessible_stores(uid uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  WITH explicit_store_access AS (
    SELECT usa.store_id
    FROM public.user_store_access usa
    JOIN public.users u
      ON u.id = usa.user_id
    JOIN public.restaurants r
      ON r.id = usa.store_id
     AND r.is_active = true
    WHERE u.auth_id = uid
      AND u.is_active = true
      AND usa.is_active = true
  ),
  fallback_store AS (
    SELECT r.id AS store_id
    FROM public.users u
    JOIN public.restaurants r
      ON r.id = COALESCE(u.primary_store_id, u.restaurant_id)
     AND r.is_active = true
    WHERE u.auth_id = uid
      AND u.is_active = true
  )
  SELECT DISTINCT store_id
  FROM (
    SELECT store_id FROM explicit_store_access
    UNION
    SELECT store_id FROM fallback_store
  ) store_scope
  WHERE store_id IS NOT NULL;
$function$;

-- ============================================================
-- Layer 2: full closure orchestration
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_close_store(
  p_store_id uuid,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_store               public.restaurants%ROWTYPE;
  v_open_orders         int;
  v_occupied            int;
  v_access_deactivated  int := 0;
  v_dests_deactivated   int := 0;
  v_jobs_cancelled      int := 0;
  v_claims_refreshed    int := 0;
  v_sales_summary       jsonb;
  v_auth                uuid;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'STORE_CLOSE_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'STORE_CLOSE_REASON_REQUIRED';
  END IF;

  SELECT * INTO v_store FROM public.restaurants WHERE id = p_store_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  IF NOT v_store.is_active THEN
    RAISE EXCEPTION 'STORE_ALREADY_CLOSED';
  END IF;

  -- Guard: no live orders (V1 decision D1: no force path — settle/cancel first)
  SELECT count(*) INTO v_open_orders
  FROM public.orders
  WHERE restaurant_id = p_store_id
    AND status IN ('pending', 'confirmed', 'serving');
  IF v_open_orders > 0 THEN
    RAISE EXCEPTION 'STORE_HAS_OPEN_ORDERS: % live order(s) must be settled or cancelled first', v_open_orders;
  END IF;

  SELECT count(*) INTO v_occupied
  FROM public.tables
  WHERE restaurant_id = p_store_id AND status = 'occupied';
  IF v_occupied > 0 THEN
    RAISE EXCEPTION 'STORE_HAS_OCCUPIED_TABLES: % table(s) still occupied', v_occupied;
  END IF;

  -- Tax-audit preservation: immutable point-in-time sales snapshot. The raw
  -- orders/payments/order_items rows are retained (closure is soft) and stay
  -- readable by super_admin (RLS is_super_admin() branch) and Office
  -- (service_role bypasses RLS). This snapshot is an at-a-glance record.
  SELECT jsonb_build_object(
    'total_orders', count(*),
    'completed_orders', count(*) FILTER (WHERE o.status = 'completed'),
    'cancelled_orders', count(*) FILTER (WHERE o.status = 'cancelled'),
    'first_order_at', min(o.created_at),
    'last_order_at', max(o.created_at),
    'lifetime_revenue', COALESCE((
      SELECT sum(p.amount) FROM public.payments p
      WHERE p.restaurant_id = p_store_id AND p.is_revenue = true), 0),
    'lifetime_revenue_payment_rows', (
      SELECT count(*) FROM public.payments p
      WHERE p.restaurant_id = p_store_id AND p.is_revenue = true)
  )
  INTO v_sales_summary
  FROM public.orders o
  WHERE o.restaurant_id = p_store_id;

  -- 1. deactivate store (same column Office reads; restaurants has no updated_at)
  UPDATE public.restaurants SET is_active = false WHERE id = p_store_id;

  -- 2. revoke staff store access
  UPDATE public.user_store_access
  SET is_active = false, updated_at = now()
  WHERE store_id = p_store_id AND is_active = true;
  GET DIAGNOSTICS v_access_deactivated = ROW_COUNT;

  -- 3. refresh claims for every affected user (explicit access + fallback users)
  FOR v_auth IN
    SELECT DISTINCT u.auth_id
    FROM public.users u
    WHERE u.auth_id IS NOT NULL
      AND (
        u.restaurant_id = p_store_id
        OR u.primary_store_id = p_store_id
        OR EXISTS (
          SELECT 1 FROM public.user_store_access usa
          WHERE usa.user_id = u.id AND usa.store_id = p_store_id
        )
      )
  LOOP
    PERFORM public.refresh_user_claims(v_auth);
    v_claims_refreshed := v_claims_refreshed + 1;
  END LOOP;

  -- 4. printer teardown
  UPDATE public.printer_destinations
  SET is_active = false, updated_at = now()
  WHERE restaurant_id = p_store_id AND is_active = true;
  GET DIAGNOSTICS v_dests_deactivated = ROW_COUNT;

  UPDATE public.print_jobs
  SET status = 'cancelled', updated_at = now()
  WHERE restaurant_id = p_store_id AND status IN ('pending', 'failed');
  GET DIAGNOSTICS v_jobs_cancelled = ROW_COUNT;

  -- 5. audit with sales snapshot (tax evidence) + orchestration summary.
  --    e-invoice/MISA queues are intentionally NOT touched: pending jobs drain
  --    through the async dispatcher and the MISA portal owns post-issuance
  --    lifecycle (CLAUDE.md §4).
  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_close_store',
    'restaurants',
    p_store_id,
    jsonb_build_object(
      'reason', p_reason,
      'sales_snapshot', v_sales_summary,
      'access_rows_deactivated', v_access_deactivated,
      'users_claims_refreshed', v_claims_refreshed,
      'printer_destinations_deactivated', v_dests_deactivated,
      'print_jobs_cancelled', v_jobs_cancelled,
      'closed_at_utc', now()
    )
  );

  RETURN jsonb_build_object(
    'store_id', p_store_id,
    'store_name', v_store.name,
    'sales_snapshot', v_sales_summary,
    'access_rows_deactivated', v_access_deactivated,
    'users_claims_refreshed', v_claims_refreshed,
    'printer_destinations_deactivated', v_dests_deactivated,
    'print_jobs_cancelled', v_jobs_cancelled
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_close_store(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_close_store(uuid, text) TO authenticated, service_role;

COMMIT;
