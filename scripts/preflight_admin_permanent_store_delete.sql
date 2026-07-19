\set ON_ERROR_STOP on

DO $$
DECLARE
  v_active_count integer;
  v_inactive_count integer;
  v_total_profile_count integer;
  v_active_profile_count integer;
  v_inactive_profile_count integer;
  v_inactive_access_count integer;
BEGIN
  IF to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.users') IS NULL
     OR to_regclass('public.user_store_access') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.payments') IS NULL
     OR to_regclass('public.einvoice_jobs') IS NULL
     OR to_regclass('public.einvoice_events') IS NULL
     OR to_regclass('public.meinvoice_jobs') IS NULL
     OR to_regclass('public.meinvoice_job_events') IS NULL
     OR to_regclass('public.office_payroll_reviews') IS NULL
     OR to_regclass('public.inventory_purchase_order_lines') IS NULL
     OR to_regclass('public.inventory_receipt_lines') IS NULL
     OR to_regclass('public.inventory_recommendation_lines') IS NULL
     OR to_regclass('public.inventory_stock_audit_lines') IS NULL
     OR to_regclass('public.photo_objet_expected_slots') IS NULL
     OR to_regclass('public.photo_objet_monitoring_policies') IS NULL
     OR to_regclass('public.employee_office_sync_outbox') IS NULL
     OR to_regclass('public.attendance_logs') IS NULL
     OR to_regclass('public.store_employees') IS NULL
     OR to_regclass('public.store_fixed_account_requirements') IS NULL
     OR to_regclass('public.store_employee_number_sequences') IS NULL
     OR to_regclass('public.b2b_buyer_cache') IS NULL
     OR to_regclass('public.store_tax_entity_history') IS NULL
     OR to_regclass('public.workforce_fixed_account_migration_state') IS NULL
     OR to_regclass('public.system_config') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_PREFLIGHT_RELATION_MISSING';
  END IF;

  IF NOT EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'workforce_fixed_account_migration_state'
         AND column_name = 'user_id'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'system_config'
         AND column_name = 'updated_by'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'store_tax_entity_history'
         AND column_name = 'created_by'
     )
     OR NOT EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'payments'
         AND column_name = 'proof_photo_by'
     ) THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_PREFLIGHT_CLEANUP_COLUMN_MISSING';
  END IF;

  SELECT count(*) FILTER (WHERE is_active),
         count(*) FILTER (WHERE NOT is_active)
  INTO v_active_count, v_inactive_count
  FROM public.restaurants;

  SELECT count(*), count(*) FILTER (WHERE is_active)
  INTO v_total_profile_count, v_active_profile_count
  FROM public.users;

  -- Recovery after the guarded store purge committed but verification found
  -- six additional inactive, banned waiter profiles with stale active-store
  -- access rows. No store deletion is repeated in this path.
  IF v_active_count = 7 AND v_inactive_count = 0 THEN
    IF to_regprocedure(
         'public.admin_purge_inactive_store(uuid,text)'
       ) IS NULL
       OR to_regprocedure(
         'public._purge_inactive_store_data(uuid,text,uuid)'
       ) IS NULL
       OR v_total_profile_count <> 20
       OR v_active_profile_count <> 14
       OR (SELECT count(*) FROM public.users WHERE NOT is_active) <> 6
       OR EXISTS (
         SELECT 1
         FROM public.users account
         LEFT JOIN auth.users identity ON identity.id = account.auth_id
         WHERE NOT account.is_active
           AND (
             account.role <> 'waiter'
             OR identity.id IS NULL
             OR identity.banned_until IS NULL
             OR identity.banned_until <= now()
           )
       )
       OR (
         SELECT count(*)
         FROM public.user_store_access access
         JOIN public.users account ON account.id = access.user_id
         WHERE NOT account.is_active
       ) <> 6
       OR EXISTS (
         SELECT 1
         FROM public.user_store_access access
         JOIN public.users account ON account.id = access.user_id
         LEFT JOIN public.restaurants store ON store.id = access.store_id
         WHERE NOT account.is_active
           AND (store.id IS NULL OR NOT store.is_active)
       )
       OR (
         SELECT count(*) FROM public.audit_logs
         WHERE action = 'admin_purge_inactive_store_profile'
       ) <> 21
       OR (
         SELECT count(*) FROM public.audit_logs
         WHERE action = 'admin_purge_inactive_store'
       ) <> 23 THEN
      RAISE EXCEPTION 'ADMIN_STORE_PURGE_PREFLIGHT_RECOVERY_SHAPE_MISMATCH';
    END IF;
    RETURN;
  END IF;

  IF to_regprocedure(
       'public.admin_purge_inactive_store(uuid,text)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public._purge_inactive_store_data(uuid,text,uuid)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_PREFLIGHT_FUNCTION_ALREADY_EXISTS';
  END IF;

  IF v_active_count <> 7 OR v_inactive_count <> 23 THEN
    RAISE EXCEPTION
      'ADMIN_STORE_PURGE_PREFLIGHT_SHAPE active=% inactive=%',
      v_active_count,
      v_inactive_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants
    WHERE id = '0446a7e2-97d3-6a53-929c-c1849a3d12c3'::uuid
      AND slug = 'smoke-in-saigon-bowl-2'
      AND NOT is_active
  ) THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_PREFLIGHT_REVIEWED_TARGET_MISSING';
  END IF;

  SELECT count(DISTINCT account.id)
  INTO v_inactive_profile_count
  FROM public.users account
  JOIN public.restaurants store
    ON store.id IN (account.restaurant_id, account.primary_store_id)
  WHERE NOT store.is_active;

  SELECT count(*)
  INTO v_inactive_access_count
  FROM public.user_store_access access
  JOIN public.restaurants store ON store.id = access.store_id
  WHERE NOT store.is_active;

  IF v_inactive_profile_count <> 21 OR v_inactive_access_count <> 23 THEN
    RAISE EXCEPTION
      'ADMIN_STORE_PURGE_PREFLIGHT_ACCOUNT_SHAPE profiles=% accesses=%',
      v_inactive_profile_count,
      v_inactive_access_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.users account
    JOIN public.restaurants store
      ON store.id IN (account.restaurant_id, account.primary_store_id)
    LEFT JOIN auth.users identity ON identity.id = account.auth_id
    WHERE NOT store.is_active
      AND (
        account.is_active
        OR identity.id IS NULL
        OR identity.banned_until IS NULL
        OR identity.banned_until <= now()
      )
  ) OR EXISTS (
    SELECT 1
    FROM public.user_store_access access
    JOIN public.users account ON account.id = access.user_id
    JOIN public.restaurants inactive_store
      ON inactive_store.id IN (account.restaurant_id, account.primary_store_id)
     AND NOT inactive_store.is_active
    JOIN public.restaurants active_store ON active_store.id = access.store_id
    WHERE active_store.is_active
  ) OR EXISTS (
    SELECT 1
    FROM public.user_store_access access
    JOIN public.restaurants inactive_store ON inactive_store.id = access.store_id
    WHERE NOT inactive_store.is_active
      AND NOT EXISTS (
        SELECT 1
        FROM public.users account
        JOIN public.restaurants linked_inactive_store
          ON linked_inactive_store.id IN (
            account.restaurant_id,
            account.primary_store_id
          )
        JOIN auth.users identity ON identity.id = account.auth_id
        WHERE account.id = access.user_id
          AND NOT linked_inactive_store.is_active
          AND NOT account.is_active
          AND identity.banned_until > now()
      )
  ) THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_PREFLIGHT_ACCOUNT_NOT_SAFE_TO_REMOVE';
  END IF;
END $$;

SELECT 'ADMIN_STORE_PURGE_PREFLIGHT_OK' AS result;
