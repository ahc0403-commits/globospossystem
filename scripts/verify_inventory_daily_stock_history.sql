\set ON_ERROR_STOP on

DO $$
DECLARE
  v_function regprocedure;
  v_config text[];
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'inventory_transactions'
      AND column_name = 'stock_before'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'inventory_transactions'
      AND column_name = 'stock_after'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'inventory_transactions'
      AND column_name = 'effective_date'
  ) THEN
    RAISE EXCEPTION 'inventory adjustment history columns are missing';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_transactions
    WHERE effective_date IS NULL
  ) THEN
    RAISE EXCEPTION 'inventory transaction operating-date backfill is incomplete';
  END IF;

  FOREACH v_function IN ARRAY ARRAY[
    'public.get_inventory_physical_count_sheet(uuid,date)'::regprocedure,
    'public.apply_inventory_physical_count_line(uuid,date,uuid,numeric,text)'::regprocedure,
    'public.save_photo_objet_daily_inventory_item(uuid,uuid,text,numeric,date,text)'::regprocedure,
    'public.record_employee_inventory_adjustment(uuid,text,uuid,text,numeric,text)'::regprocedure,
    'public.get_inventory_stock_adjustment_history(uuid,date,date,integer)'::regprocedure
  ]
  LOOP
    SELECT proconfig
    INTO v_config
    FROM pg_proc
    WHERE oid = v_function;

    IF NOT EXISTS (
      SELECT 1
      FROM pg_proc
      WHERE oid = v_function
        AND prosecdef
    ) THEN
      RAISE EXCEPTION '% must remain SECURITY DEFINER', v_function;
    END IF;

    IF NOT (
      'search_path=public, auth, pg_catalog' = ANY(v_config)
    ) THEN
      RAISE EXCEPTION '% has an unsafe search_path', v_function;
    END IF;

    IF has_function_privilege(
      'anon',
      v_function,
      'EXECUTE'
    ) OR NOT has_function_privilege(
      'authenticated',
      v_function,
      'EXECUTE'
    ) THEN
      RAISE EXCEPTION '% has incorrect Data API grants', v_function;
    END IF;
  END LOOP;

  v_function :=
    'public.upsert_photo_objet_inventory_item(uuid,uuid,text,numeric)'::regprocedure;
  SELECT proconfig
  INTO v_config
  FROM pg_proc
  WHERE oid = v_function;

  IF EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE oid = v_function
      AND prosecdef
  ) OR NOT (
    'search_path=public, auth, pg_catalog' = ANY(v_config)
  ) OR has_function_privilege(
    'anon',
    v_function,
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated',
    v_function,
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'legacy Photo inventory wrapper is not safely delegated';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'inventory_transactions_store_effective_date_idx'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'inventory_physical_counts_store_date_idx'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'inventory_transactions_created_by_idx'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'inventory_transactions_employee_idx'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'inventory_physical_counts_counted_by_idx'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'inventory_physical_counts_employee_idx'
  ) THEN
    RAISE EXCEPTION 'inventory history indexes are missing';
  END IF;
END;
$$;

SELECT 'inventory daily stock verification passed' AS result;
