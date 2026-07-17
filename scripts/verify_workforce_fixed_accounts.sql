BEGIN;
SET TRANSACTION READ ONLY;

DO $$
DECLARE
  v_signature text;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'public.create_store_employee(uuid,text,text,text,text,text)',
    'public.update_store_employee(uuid,uuid,text,text,text,text,text)',
    'public.deactivate_store_employee(uuid,uuid)',
    'public.record_employee_attendance(uuid,text,text)',
    'public.record_employee_inventory_adjustment(uuid,text,uuid,text,numeric,text)',
    'public.admin_configure_store_workforce(uuid,text,text,integer,jsonb)',
    'public.admin_get_store_workforce_readiness(uuid)',
    'public.office_list_employee_payment_profiles(bigint,integer)'
  ] LOOP
    IF to_regprocedure(v_signature) IS NULL THEN
      RAISE EXCEPTION 'WORKFORCE_VERIFY_RPC_MISSING:%', v_signature;
    END IF;
  END LOOP;

  IF to_regclass('public.store_employees') IS NULL
     OR to_regclass('public.store_employee_number_sequences') IS NULL
     OR to_regclass('public.store_fixed_account_requirements') IS NULL
     OR to_regclass('public.employee_office_sync_outbox') IS NULL
     OR to_regclass('public.workforce_fixed_account_function_state') IS NULL THEN
    RAISE EXCEPTION 'WORKFORCE_VERIFY_TABLE_MISSING';
  END IF;

  IF has_function_privilege('anon',
       'public.record_employee_attendance(uuid,text,text)', 'EXECUTE')
     OR has_function_privilege('authenticated',
       'public.office_list_employee_payment_profiles(bigint,integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role',
       'public.office_list_employee_payment_profiles(bigint,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'WORKFORCE_VERIFY_FUNCTION_GRANT_INVALID';
  END IF;

  IF has_table_privilege('service_role', 'public.store_employees', 'SELECT')
     OR has_table_privilege('service_role', 'public.employee_office_sync_outbox', 'SELECT')
     OR has_table_privilege('service_role',
       'public.workforce_fixed_account_migration_state', 'SELECT')
     OR has_table_privilege('service_role',
       'public.workforce_fixed_account_function_state', 'SELECT') THEN
    RAISE EXCEPTION 'WORKFORCE_VERIFY_SERVICE_ROLE_DIRECT_ACCESS_PRESENT';
  END IF;

  IF (SELECT count(*) FROM public.workforce_fixed_account_function_state
      WHERE function_signature = 'public.require_admin_actor_for_restaurant(uuid)'
        AND definition_fingerprint = md5(original_definition)) <> 1 THEN
    RAISE EXCEPTION 'WORKFORCE_VERIFY_FUNCTION_BACKUP_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.users
    WHERE role = 'photo_objet_store_admin' AND is_active = true
  ) THEN
    RAISE EXCEPTION 'WORKFORCE_VERIFY_LEGACY_PHOTO_ADMIN_ACTIVE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.users u
    LEFT JOIN public.workforce_fixed_account_migration_state s
      ON s.user_id = u.id
    WHERE u.role = 'photo_objet_store_admin' AND s.user_id IS NULL
  ) OR EXISTS (
    SELECT 1
    FROM public.workforce_fixed_account_migration_state s
    LEFT JOIN public.users u ON u.id = s.user_id
    WHERE u.id IS NULL
      OR s.original_role <> 'photo_objet_store_admin'
      OR u.role <> 'photo_objet_store_admin'
      OR u.is_active = true
  ) THEN
    RAISE EXCEPTION 'WORKFORCE_VERIFY_LEGACY_PHOTO_BACKUP_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'employee_office_sync_outbox'
      AND column_name NOT IN ('employee_id', 'profile_version', 'changed_at')
  ) THEN
    RAISE EXCEPTION 'WORKFORCE_VERIFY_OUTBOX_CONTAINS_PAYLOAD';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.store_employees e
    LEFT JOIN public.restaurants r ON r.id = e.store_id
    WHERE r.id IS NULL
      OR e.employee_number !~ ('^' || r.short_code || '[1-9][0-9]*$')
  ) THEN
    RAISE EXCEPTION 'WORKFORCE_VERIFY_EMPLOYEE_NUMBER_MAPPING_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.employee_office_sync_outbox o
    LEFT JOIN public.store_employees e
      ON e.id = o.employee_id AND e.payment_profile_version >= o.profile_version
    WHERE e.id IS NULL
  ) THEN
    RAISE EXCEPTION 'WORKFORCE_VERIFY_OUTBOX_ORPHAN_OR_VERSION_INVALID';
  END IF;
END;
$$;

COMMIT;
SELECT 'WORKFORCE_FIXED_ACCOUNTS_VERIFY_OK' AS result;
