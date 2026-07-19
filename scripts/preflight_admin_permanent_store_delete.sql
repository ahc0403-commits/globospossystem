\set ON_ERROR_STOP on

DO $$
DECLARE
  v_active_count integer;
  v_inactive_count integer;
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
     OR to_regclass('public.inventory_receipt_confirmation_attempts') IS NULL
     OR to_regclass('public.photo_objet_expected_slots') IS NULL
     OR to_regclass('public.photo_objet_monitoring_policies') IS NULL
     OR to_regclass('public.employee_office_sync_outbox') IS NULL
     OR to_regclass('public.attendance_logs') IS NULL
     OR to_regclass('public.store_employees') IS NULL
     OR to_regclass('public.store_fixed_account_requirements') IS NULL
     OR to_regclass('public.store_employee_number_sequences') IS NULL
     OR to_regclass('public.b2b_buyer_cache') IS NULL
     OR to_regclass('public.store_tax_entity_history') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_PREFLIGHT_RELATION_MISSING';
  END IF;

  IF to_regprocedure(
       'public.admin_purge_inactive_store(uuid,text)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public._purge_inactive_store_data(uuid,text,uuid)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_PREFLIGHT_FUNCTION_ALREADY_EXISTS';
  END IF;

  SELECT count(*) FILTER (WHERE is_active),
         count(*) FILTER (WHERE NOT is_active)
  INTO v_active_count, v_inactive_count
  FROM public.restaurants;

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

  IF EXISTS (
    SELECT 1
    FROM public.users account
    JOIN public.restaurants store
      ON store.id IN (account.restaurant_id, account.primary_store_id)
    WHERE NOT store.is_active
  ) OR EXISTS (
    SELECT 1
    FROM public.user_store_access access
    JOIN public.restaurants store ON store.id = access.store_id
    WHERE NOT store.is_active
  ) THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_PREFLIGHT_INACTIVE_STORE_HAS_ACCOUNTS';
  END IF;
END $$;

SELECT 'ADMIN_STORE_PURGE_PREFLIGHT_OK' AS result;
