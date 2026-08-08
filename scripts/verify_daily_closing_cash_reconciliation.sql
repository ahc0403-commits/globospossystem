\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_function regprocedure;
BEGIN
  IF (
    SELECT count(*)
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'daily_closings'
      AND column_name IN (
        'opening_cash_amount', 'cash_denominations', 'expected_cash_amount',
        'counted_cash_amount', 'cash_variance'
      )
  ) <> 5 THEN
    RAISE EXCEPTION 'DAILY_CLOSING_CASH_COLUMNS_MISSING';
  END IF;

  FOREACH v_function IN ARRAY ARRAY[
    'public.get_daily_closing_cash_preview(uuid)'::regprocedure,
    'public.create_daily_closing(uuid,text,jsonb,numeric)'::regprocedure,
    'public.get_daily_closings(uuid,integer)'::regprocedure
  ]
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc
      WHERE oid = v_function
        AND prosecdef
        AND 'search_path=public, auth' = ANY(proconfig)
    ) OR has_function_privilege('anon', v_function, 'EXECUTE')
      OR NOT has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'DAILY_CLOSING_CASH_FUNCTION_SECURITY_INVALID: %', v_function;
    END IF;
  END LOOP;

  IF to_regprocedure('public.create_daily_closing(uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'DAILY_CLOSING_LEGACY_OVERLOAD_STILL_PRESENT';
  END IF;
END
$verify$;

SELECT 'DAILY_CLOSING_CASH_VERIFY_OK' AS result;
