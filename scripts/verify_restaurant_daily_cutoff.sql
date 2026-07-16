\set ON_ERROR_STOP on

DO $$
DECLARE
  v_bad integer;
  v_definition text;
  v_photo_overlap integer := 0;
BEGIN
  IF to_regclass('public.restaurant_cutoff_policies') IS NULL
     OR to_regclass('public.restaurant_daily_sales_finalizations') IS NULL
     OR to_regclass('public.v_restaurant_sales_receipts') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_RELATION_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurant_cutoff_policies
    WHERE is_enabled = true
  ) THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_NO_ACTIVE_RESTAURANT';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger
    WHERE trigger.tgname = 'trg_restaurant_finalization_immutable'
      AND trigger.tgrelid =
          'public.restaurant_daily_sales_finalizations'::regclass
      AND NOT trigger.tgisinternal
  ) THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_IMMUTABILITY_FAILED';
  END IF;

  SELECT count(*) INTO v_bad
  FROM (
    VALUES
      ('trg_restaurant_cutoff_orders', 'orders'),
      ('trg_restaurant_cutoff_order_items', 'order_items'),
      ('trg_restaurant_cutoff_payments', 'payments'),
      ('trg_restaurant_cutoff_external_sales', 'external_sales')
  ) expected(trigger_name, table_name)
  LEFT JOIN pg_trigger trigger
    ON trigger.tgname = expected.trigger_name
   AND trigger.tgrelid = to_regclass('public.' || expected.table_name)
   AND NOT trigger.tgisinternal
  WHERE trigger.oid IS NULL OR NOT trigger.tgenabled = 'O';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_TRIGGER_FAILED: %', v_bad;
  END IF;

  v_definition := pg_get_functiondef(
    'public.enforce_restaurant_daily_cutoff()'::regprocedure
  );
  IF v_definition NOT LIKE '%statement_timestamp()%'
     OR v_definition LIKE '%current_setting(%' THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_SERVER_TIME_FAILED';
  END IF;

  IF pg_get_functiondef(
       'public.restaurant_assert_kitchen_mutation_allowed_at(uuid,timestamptz)'::regprocedure
     ) NOT LIKE '%RESTAURANT_KITCHEN_CLOSED%'
     OR pg_get_functiondef(
       'public.restaurant_assert_payment_allowed_at(uuid,timestamptz)'::regprocedure
     ) NOT LIKE '%RESTAURANT_DAILY_SALES_CLOSED%' THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_STABLE_ERROR_FAILED';
  END IF;

  v_definition := pg_get_functiondef(
    'public.restaurant_cutoff_state_at(uuid,timestamptz)'::regprocedure
  );
  IF v_definition NOT LIKE '%21:30:00%'
     OR v_definition NOT LIKE '%21:45:00%'
     OR v_definition NOT LIKE '%Asia/Ho_Chi_Minh%' THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_BOUNDARY_FAILED';
  END IF;

  v_definition := pg_get_functiondef(
    'public.restaurant_finalize_daily_sales_at(date,timestamptz)'::regprocedure
  );
  IF v_definition NOT LIKE '%22:20:00%'
     OR v_definition NOT LIKE '%data_integrity_failed%'
     OR v_definition NOT LIKE '%post_cutoff_receipt_count%'
     OR v_definition LIKE '%23:00%'
     OR v_definition LIKE '%22:30%' THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_FINALIZATION_FAILED';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.restaurant_cutoff_state_at(uuid,timestamptz)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.restaurant_assert_kitchen_mutation_allowed_at(uuid,timestamptz)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.restaurant_assert_payment_allowed_at(uuid,timestamptz)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.restaurant_finalize_daily_sales_at(date,timestamptz)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.get_restaurant_cutoff_state(uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_PRIVILEGE_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc proc
    WHERE proc.oid =
      'public.restaurant_cutoff_state_at(uuid,timestamptz)'::regprocedure
      AND proc.prosecdef
  ) THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_FAIL_CLOSED_STATE_FAILED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc proc
    WHERE proc.oid IN (
      'public.restaurant_assert_kitchen_mutation_allowed_at(uuid,timestamptz)'::regprocedure,
      'public.restaurant_assert_payment_allowed_at(uuid,timestamptz)'::regprocedure,
      'public.enforce_restaurant_daily_cutoff()'::regprocedure
    )
      AND proc.prosecdef
  ) THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_CALLER_IDENTITY_FAILED';
  END IF;

  IF to_regclass('public.photo_objet_monitoring_policies') IS NOT NULL THEN
    SELECT count(*) INTO v_photo_overlap
    FROM public.restaurant_cutoff_policies restaurant_policy
    JOIN public.photo_objet_monitoring_policies photo_policy
      ON photo_policy.store_id = restaurant_policy.restaurant_id
     AND photo_policy.is_enabled = true
     AND photo_policy.effective_to IS NULL
    WHERE restaurant_policy.is_enabled = true;
  END IF;
  IF v_photo_overlap <> 0 THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_PHOTO_OVERLAP: %', v_photo_overlap;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class relation
    WHERE relation.oid = 'public.restaurants'::regclass
      AND relation.relkind NOT IN ('r', 'p')
  )
     OR to_regclass('public.restaurant_settings') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_OFFICE_CONTRACT_FAILED';
  END IF;

  IF to_regclass('public.photo_objet_sales_raw') IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM pg_trigger trigger
       WHERE trigger.tgrelid = 'public.photo_objet_sales_raw'::regclass
         AND trigger.tgname = 'trg_enqueue_photo_objet_meinvoice_job'
         AND NOT trigger.tgisinternal
     ) THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_PHOTO_MISA_TRIGGER_PRESENT';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    SELECT count(*) INTO v_bad
    FROM cron.job
    WHERE jobname = 'restaurant-daily-sales-finalize-2220-hcm'
      AND schedule = '20 15 * * *';
    IF v_bad <> 1 THEN
      RAISE EXCEPTION 'RESTAURANT_CUTOFF_VERIFY_SCHEDULE_FAILED: %', v_bad;
    END IF;
  END IF;
END $$;

SELECT 'RESTAURANT_CUTOFF_VERIFY_OK' AS result;
