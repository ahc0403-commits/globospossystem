DO $$
BEGIN
  IF to_regclass('public.restaurant_settings') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'PAYROLL_PIN_REPAIR_PREFLIGHT_TABLE_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'restaurant_settings'
      AND column_name = 'payroll_pin'
  ) THEN
    RAISE EXCEPTION 'PAYROLL_PIN_REPAIR_PREFLIGHT_COLUMN_MISSING';
  END IF;

  IF to_regprocedure(
    'public.require_admin_actor_for_restaurant(uuid)'
  ) IS NULL THEN
    RAISE EXCEPTION 'PAYROLL_PIN_REPAIR_PREFLIGHT_ADMIN_HELPER_MISSING';
  END IF;
END;
$$;

SELECT 'payroll PIN RPC repair preflight passed' AS result;
