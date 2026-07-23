DO $preflight_cashier_non_revenue_checkout$
BEGIN
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.payments') IS NULL
     OR to_regclass('public.order_discounts') IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_PREFLIGHT_TABLES_MISSING';
  END IF;

  IF to_regprocedure('public.process_payment(uuid,uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_PREFLIGHT_PROCESS_PAYMENT_MISSING';
  END IF;

  IF to_regprocedure(
    'public.verify_discount_manager_pin_or_raise(uuid,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_PREFLIGHT_MANAGER_PIN_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.orders'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%order_purpose%staff_meal%'
  ) THEN
    RAISE EXCEPTION 'NON_REVENUE_PREFLIGHT_STAFF_MEAL_CONTRACT_MISSING';
  END IF;
END;
$preflight_cashier_non_revenue_checkout$;

SELECT 'cashier non-revenue checkout preflight passed' AS result;
