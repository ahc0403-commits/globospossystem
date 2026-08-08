\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.daily_closings') IS NULL
     OR to_regclass('public.payments') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.order_items') IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSING_CASH_REQUIRED_RELATION_MISSING';
  END IF;

  IF to_regprocedure('public.require_pos_admin_actor_for_store(uuid,text)') IS NULL
     OR to_regprocedure('public.create_daily_closing(uuid,text)') IS NULL
     OR to_regprocedure('public.get_daily_closings(uuid,integer)') IS NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSING_CASH_REQUIRED_FUNCTION_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'payments'
      AND column_name = 'amount_portion'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'daily_closings'
      AND column_name = 'close_source'
  ) THEN
    RAISE EXCEPTION 'DAILY_CLOSING_CASH_REQUIRED_COLUMN_MISSING';
  END IF;
END
$preflight$;

SELECT 'DAILY_CLOSING_CASH_PREFLIGHT_OK' AS result;
