BEGIN;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.store_employees)
     OR EXISTS (SELECT 1 FROM public.store_fixed_account_requirements)
     OR EXISTS (SELECT 1 FROM public.store_employee_number_sequences)
     OR EXISTS (SELECT 1 FROM public.users WHERE fixed_account_code IS NOT NULL)
     OR EXISTS (SELECT 1 FROM public.users WHERE role = 'photo_objet_store_operator')
     OR EXISTS (SELECT 1 FROM public.restaurants WHERE short_code IS NOT NULL) THEN
    RAISE EXCEPTION 'WORKFORCE_ROLLBACK_BLOCKED_LIVE_FEATURE_DATA';
  END IF;
END;
$$;

DROP POLICY IF EXISTS store_employees_manager_read ON public.store_employees;
DROP POLICY IF EXISTS fixed_account_requirements_manager_read
  ON public.store_fixed_account_requirements;
DROP FUNCTION IF EXISTS public.office_list_employee_payment_profiles(bigint, integer);
DROP FUNCTION IF EXISTS public.admin_get_store_workforce_readiness(uuid);
DROP FUNCTION IF EXISTS public.admin_configure_store_workforce(uuid, text, text, integer, jsonb);
DROP FUNCTION IF EXISTS public.record_employee_inventory_adjustment(uuid, text, uuid, text, numeric, text);
DROP FUNCTION IF EXISTS public.record_employee_attendance(uuid, text, text);
DROP FUNCTION IF EXISTS public.deactivate_store_employee(uuid, uuid);
DROP FUNCTION IF EXISTS public.update_store_employee(uuid, uuid, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.create_store_employee(uuid, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.require_workforce_manager(uuid);
DROP FUNCTION IF EXISTS public.workforce_can_manage_store(uuid);

ALTER TABLE public.inventory_physical_counts
  DROP COLUMN IF EXISTS performed_by_employee_id;
ALTER TABLE public.inventory_transactions
  DROP COLUMN IF EXISTS performed_by_employee_id;
ALTER TABLE public.attendance_logs DROP CONSTRAINT IF EXISTS attendance_logs_actor_check;
ALTER TABLE public.attendance_logs DROP COLUMN IF EXISTS recorded_by_user_id;
ALTER TABLE public.attendance_logs DROP COLUMN IF EXISTS employee_id;
ALTER TABLE public.attendance_logs ALTER COLUMN user_id SET NOT NULL;

DROP TABLE IF EXISTS public.employee_office_sync_outbox;
DROP TRIGGER IF EXISTS store_employee_outbox_after_write ON public.store_employees;
DROP TRIGGER IF EXISTS store_employee_profile_before_write ON public.store_employees;
DROP FUNCTION IF EXISTS public.store_employee_outbox_append_trigger();
DROP FUNCTION IF EXISTS public.store_employee_profile_outbox_trigger();
DROP TABLE IF EXISTS public.store_employees;
DROP SEQUENCE IF EXISTS public.store_employee_payment_profile_version_seq;
DROP TABLE IF EXISTS public.store_employee_number_sequences;
DROP TABLE IF EXISTS public.store_fixed_account_requirements;

DO $$
DECLARE
  v_definition text;
  v_fingerprint text;
BEGIN
  SELECT original_definition, definition_fingerprint
  INTO v_definition, v_fingerprint
  FROM public.workforce_fixed_account_function_state
  WHERE function_signature = 'public.require_admin_actor_for_restaurant(uuid)';
  IF v_definition IS NULL OR md5(v_definition) <> v_fingerprint THEN
    RAISE EXCEPTION 'WORKFORCE_ROLLBACK_FUNCTION_BACKUP_INVALID';
  END IF;
  EXECUTE v_definition;
END;
$$;
DROP TABLE public.workforce_fixed_account_function_state;

UPDATE public.users u SET
  is_active = s.original_is_active,
  role = s.original_role
FROM public.workforce_fixed_account_migration_state s
WHERE s.user_id = u.id;
DROP TABLE public.workforce_fixed_account_migration_state;

ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE public.users ADD CONSTRAINT users_role_check CHECK (role IN (
  'super_admin', 'master_admin', 'brand_admin', 'store_admin', 'admin',
  'waiter', 'kitchen', 'cashier', 'photo_objet_master',
  'photo_objet_store_admin'
));
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_fixed_account_code_check;
ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_account_type_check;
DROP INDEX IF EXISTS public.users_fixed_account_code_unique;
ALTER TABLE public.users DROP COLUMN IF EXISTS fixed_account_code;
ALTER TABLE public.users DROP COLUMN IF EXISTS account_type;

ALTER TABLE public.restaurants DROP CONSTRAINT IF EXISTS restaurants_short_code_check;
DROP INDEX IF EXISTS public.restaurants_short_code_unique;
ALTER TABLE public.restaurants DROP COLUMN IF EXISTS short_code;

ALTER TABLE public.brands DROP CONSTRAINT IF EXISTS brands_brand_manager_slots_check;
ALTER TABLE public.brands DROP CONSTRAINT IF EXISTS brands_management_model_check;
ALTER TABLE public.brands DROP COLUMN IF EXISTS brand_manager_slots;
ALTER TABLE public.brands DROP COLUMN IF EXISTS management_model;

COMMIT;
SELECT 'WORKFORCE_FIXED_ACCOUNTS_ROLLBACK_OK' AS result;
