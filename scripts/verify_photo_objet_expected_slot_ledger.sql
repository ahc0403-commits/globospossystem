\set ON_ERROR_STOP on

DO $$
DECLARE
  v_bad integer;
BEGIN
  IF to_regclass('public.photo_objet_monitoring_policies') IS NULL
     OR to_regclass('public.photo_objet_expected_slots') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_TABLE_MISSING';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.photo_objet_monitoring_policies WHERE is_enabled = true
  ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_ACTIVE_POLICY_MISSING';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.photo_objet_monitoring_policies p
    JOIN public.restaurants r ON r.id = p.store_id
    WHERE p.is_enabled = true AND r.is_active IS DISTINCT FROM true
  ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_INACTIVE_POLICY_ENABLED';
  END IF;
  IF to_regprocedure('public.photo_objet_ensure_expected_slots(date,date)') IS NULL
     OR to_regprocedure('public.photo_objet_refresh_expected_slot_health(timestamp with time zone,integer)') IS NULL
     OR to_regprocedure('public.photo_objet_expected_slot_health_at(timestamp with time zone,integer)') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_FUNCTION_MISSING';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'photo_objet_sales_pull_runs'
      AND column_name = 'interval_rows'
  ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_INTERVAL_ROWS_MISSING';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_attribute a
    WHERE a.attrelid = 'public.photo_objet_sales_pull_runs'::regclass
      AND a.attname = 'interval_rows'
      AND NOT a.attisdropped
      AND format_type(a.atttypid, a.atttypmod) = 'integer'
  ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_INTERVAL_ROWS_TYPE_FAILED';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conrelid = 'public.photo_objet_sales_pull_runs'::regclass
      AND c.conname = 'photo_objet_pull_run_interval_rows_check'
      AND pg_get_constraintdef(c.oid, true)
        = 'CHECK (interval_rows IS NULL OR interval_rows >= 0)'
  ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_INTERVAL_ROWS_CONSTRAINT_FAILED';
  END IF;
  IF col_description(
    'public.photo_objet_sales_pull_runs'::regclass,
    (SELECT attnum FROM pg_attribute
     WHERE attrelid = 'public.photo_objet_sales_pull_runs'::regclass
       AND attname = 'interval_rows' AND NOT attisdropped)
  ) IS DISTINCT FROM
    'Rows selected inside this exact typed interval; independent from daily aggregate device count.' THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_INTERVAL_ROWS_COMMENT_FAILED';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_slot_20260713120000_state
    WHERE migration_id = '20260713120000'
      AND pull_run_interval_rows_existed IS NOT NULL
      AND pull_run_interval_rows_constraint_existed IS NOT NULL
      AND (
        pull_run_interval_rows_existed = false
        OR pull_run_interval_rows_data_type IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_INTERVAL_ROWS_BACKUP_INCOMPLETE';
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_objet_expected_slots s
  JOIN public.photo_objet_monitoring_policies p ON p.id = s.monitoring_policy_id
  WHERE s.scheduled_at < p.effective_from
     OR (p.effective_to IS NOT NULL AND s.scheduled_at >= p.effective_to);
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_POLICY_PERIOD_VIOLATION: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_objet_expected_slots s
  JOIN public.restaurants r ON r.id = s.store_id
  WHERE r.is_active = false AND s.created_at > now() - interval '5 minutes';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_INACTIVE_EXPECTATION: %', v_bad;
  END IF;

  IF has_table_privilege('anon', 'public.photo_objet_expected_slots', 'SELECT')
     OR has_table_privilege('authenticated', 'public.photo_objet_expected_slots', 'INSERT')
     OR has_function_privilege(
       'authenticated',
       'public.photo_objet_refresh_expected_slot_health(timestamp with time zone,integer)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_PRIVILEGE_TOO_BROAD';
  END IF;
  IF has_table_privilege('service_role', 'public.photo_slot_20260713120000_state', 'SELECT')
     OR has_table_privilege('service_role', 'public.photo_slot_20260713120000_state', 'INSERT')
     OR has_table_privilege('service_role', 'public.photo_slot_20260713120000_state', 'UPDATE')
     OR has_table_privilege('service_role', 'public.photo_slot_20260713120000_state', 'DELETE')
     OR has_table_privilege('service_role', 'public.photo_objet_monitoring_policies', 'INSERT')
     OR has_table_privilege('service_role', 'public.photo_objet_monitoring_policies', 'UPDATE')
     OR has_table_privilege('service_role', 'public.photo_objet_monitoring_policies', 'DELETE')
     OR has_table_privilege('service_role', 'public.photo_objet_expected_slots', 'INSERT')
     OR has_table_privilege('service_role', 'public.photo_objet_expected_slots', 'UPDATE')
     OR has_table_privilege('service_role', 'public.photo_objet_expected_slots', 'DELETE')
     OR NOT has_function_privilege(
       'service_role',
       'public.photo_objet_ack_expected_slot_alert(uuid,date,time without time zone,text,timestamp with time zone)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_SERVICE_WRITE_BOUNDARY_FAILED';
  END IF;

  WITH slot_times(slot_time) AS (
    VALUES
      (TIME '09:00'), (TIME '10:00'), (TIME '11:00'), (TIME '12:00'),
      (TIME '13:00'), (TIME '14:00'), (TIME '15:00'), (TIME '16:00'),
      (TIME '17:00'), (TIME '18:00'), (TIME '19:00'), (TIME '20:00'),
      (TIME '21:00'), (TIME '22:00'), (TIME '22:30')
  ), candidates AS (
    SELECT p.id AS policy_id, p.store_id,
      (p.effective_from AT TIME ZONE p.timezone)::date AS target_date,
      st.slot_time
    FROM public.photo_objet_monitoring_policies p
    CROSS JOIN slot_times st
    WHERE p.is_enabled = true
      AND (
        (p.effective_from AT TIME ZONE p.timezone)::date + st.slot_time
      ) AT TIME ZONE p.timezone >= p.effective_from
      AND (
        p.effective_to IS NULL OR (
          (p.effective_from AT TIME ZONE p.timezone)::date + st.slot_time
        ) AT TIME ZONE p.timezone < p.effective_to
      )
  )
  SELECT count(*) INTO v_bad
  FROM candidates candidate
  LEFT JOIN public.photo_objet_expected_slots slot
    ON slot.monitoring_policy_id = candidate.policy_id
   AND slot.store_id = candidate.store_id
   AND slot.slot_date_hcm = candidate.target_date
   AND slot.slot_time_hcm = candidate.slot_time
  WHERE slot.id IS NULL;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_SLOT_VERIFY_INITIAL_MATERIALIZATION_MISSING: %', v_bad;
  END IF;
END $$;

SELECT 'PHOTO_OBJET_EXPECTED_SLOT_VERIFY_PASS' AS result;
