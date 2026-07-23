DO $verify_cashier_non_revenue_checkout$
DECLARE
  v_missing_columns text[];
BEGIN
  SELECT array_agg(required.column_name ORDER BY required.column_name)
  INTO v_missing_columns
  FROM (
    VALUES
      ('non_revenue_type'),
      ('non_revenue_reason'),
      ('non_revenue_staff_name'),
      ('non_revenue_classified_by'),
      ('non_revenue_classified_at')
  ) AS required(column_name)
  WHERE NOT EXISTS (
    SELECT 1
    FROM information_schema.columns c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'orders'
      AND c.column_name = required.column_name
  );

  IF v_missing_columns IS NOT NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_VERIFY_COLUMNS_MISSING: %', v_missing_columns;
  END IF;

  IF to_regprocedure(
    'public.process_non_revenue_payment(uuid,uuid,numeric,text,text,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_VERIFY_RPC_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.payments'::regclass
      AND tgname = 'payments_require_non_revenue_classification'
      AND tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'NON_REVENUE_VERIFY_PAYMENT_TRIGGER_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.order_discounts'::regclass
      AND tgname = 'order_discounts_require_reason'
      AND tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'NON_REVENUE_VERIFY_DISCOUNT_TRIGGER_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.orders'::regclass
      AND tgname = 'orders_normalize_staff_meal_classification'
      AND tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'NON_REVENUE_VERIFY_STAFF_TRIGGER_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.orders
    WHERE order_purpose = 'staff_meal'
      AND (
        non_revenue_type IS DISTINCT FROM 'staff_meal'
        OR NULLIF(btrim(COALESCE(non_revenue_reason, '')), '') IS NULL
        OR NULLIF(btrim(COALESCE(non_revenue_staff_name, '')), '') IS NULL
      )
  ) THEN
    RAISE EXCEPTION 'NON_REVENUE_VERIFY_STAFF_BACKFILL_INCOMPLETE';
  END IF;

  IF position(
    'NON_REVENUE_REASON_REQUIRED'
    IN pg_get_functiondef(
      'public.process_non_revenue_payment(uuid,uuid,numeric,text,text,text,text)'::regprocedure
    )
  ) = 0 OR position(
    'process_payment'
    IN pg_get_functiondef(
      'public.process_non_revenue_payment(uuid,uuid,numeric,text,text,text,text)'::regprocedure
    )
  ) = 0 THEN
    RAISE EXCEPTION 'NON_REVENUE_VERIFY_ATOMIC_RPC_CONTRACT_MISSING';
  END IF;
END;
$verify_cashier_non_revenue_checkout$;

SELECT 'cashier non-revenue checkout verification passed' AS result;
