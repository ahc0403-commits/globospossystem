\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_rls_enabled boolean;
  v_immutable_trigger_enabled "char";
BEGIN
  IF to_regclass('public.order_cancellation_reversals') IS NULL
     OR to_regprocedure('public.cancel_order(uuid,uuid,boolean)') IS NULL
     OR to_regprocedure('public.cancel_order_item(uuid,uuid)') IS NULL
     OR to_regprocedure('public.restore_cancelled_order(uuid,uuid)') IS NULL
     OR to_regprocedure('public.restore_cancelled_order_item(uuid,uuid)') IS NULL
     OR to_regprocedure(
       'public.get_store_sales_cancellation_total(uuid,timestamp with time zone,timestamp with time zone)'
     ) IS NULL THEN
    RAISE EXCEPTION 'CANCELLATION_RESTORE_OBJECT_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_cancellation_ledger'
      AND column_name = 'order_status_snapshot'
      AND data_type = 'text'
  ) THEN
    RAISE EXCEPTION 'CANCELLATION_RESTORE_SNAPSHOT_COLUMN_MISSING';
  END IF;

  SELECT relrowsecurity INTO v_rls_enabled
  FROM pg_class
  WHERE oid = 'public.order_cancellation_reversals'::regclass;
  IF NOT COALESCE(v_rls_enabled, false) THEN
    RAISE EXCEPTION 'CANCELLATION_RESTORE_RLS_DISABLED';
  END IF;

  SELECT tgenabled INTO v_immutable_trigger_enabled
  FROM pg_trigger
  WHERE tgrelid = 'public.order_cancellation_reversals'::regclass
    AND tgname = 'order_cancellation_reversals_immutable'
    AND NOT tgisinternal;
  IF v_immutable_trigger_enabled IS DISTINCT FROM 'O'::"char" THEN
    RAISE EXCEPTION 'CANCELLATION_RESTORE_IMMUTABLE_TRIGGER_MISSING';
  END IF;

  IF to_regclass('public.order_cancellation_ledger_order_once_idx') IS NOT NULL
     OR to_regclass('public.order_cancellation_ledger_item_once_idx') IS NOT NULL THEN
    RAISE EXCEPTION 'CANCELLATION_RESTORE_REPEAT_CYCLE_INDEX_PRESENT';
  END IF;

  IF has_table_privilege(
       'authenticated',
       'public.order_cancellation_reversals',
       'INSERT,UPDATE,DELETE'
     )
     OR has_function_privilege(
       'anon', 'public.restore_cancelled_order(uuid,uuid)', 'EXECUTE'
     )
     OR has_function_privilege(
       'anon', 'public.restore_cancelled_order_item(uuid,uuid)', 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated', 'public.restore_cancelled_order(uuid,uuid)', 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.get_store_sales_cancellation_total(uuid,timestamp with time zone,timestamp with time zone)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'CANCELLATION_RESTORE_PRIVILEGE_INVALID';
  END IF;
END
$verify$;

SELECT 'Cancellation restore/live sales verification passed' AS result;
