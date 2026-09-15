DO $preflight$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.audit_logs') IS NULL THEN
    v_missing := array_append(v_missing, 'public.audit_logs');
  END IF;
  IF to_regclass('public.order_cancellation_ledger') IS NULL THEN
    v_missing := array_append(v_missing, 'public.order_cancellation_ledger');
  END IF;
  IF to_regclass('public.order_cancellation_reversals') IS NULL THEN
    v_missing := array_append(v_missing, 'public.order_cancellation_reversals');
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    v_missing := array_append(v_missing, 'public.orders');
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'orders'
      AND column_name = 'order_purpose'
  ) THEN
    v_missing := array_append(v_missing, 'public.orders.order_purpose');
  END IF;
  IF to_regclass('public.order_items') IS NULL THEN
    v_missing := array_append(v_missing, 'public.order_items');
  END IF;
  IF to_regclass('public.restaurants') IS NULL THEN
    v_missing := array_append(v_missing, 'public.restaurants');
  END IF;
  IF to_regclass('public.users') IS NULL THEN
    v_missing := array_append(v_missing, 'public.users');
  END IF;
  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    v_missing := array_append(
      v_missing,
      'public.user_accessible_stores(uuid)'
    );
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION
      'BM menu exception history prerequisites are missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END;
$preflight$;
