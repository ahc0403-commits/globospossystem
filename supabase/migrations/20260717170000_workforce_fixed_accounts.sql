BEGIN;

-- Fixed POS accounts and auth-less workforce records are deliberately kept
-- separate: public.users remains the Supabase Auth/device identity table while
-- store_employees is the store-owned human directory.
DO $$
DECLARE
  v_name text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'brands', 'restaurants', 'users', 'user_brand_access',
    'user_store_access', 'attendance_logs', 'inventory_transactions',
    'inventory_physical_counts'
  ] LOOP
    IF to_regclass('public.' || v_name) IS NULL THEN
      RAISE EXCEPTION 'WORKFORCE_PREFLIGHT_MISSING_TABLE:%', v_name;
    END IF;
  END LOOP;
  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION 'WORKFORCE_PREFLIGHT_MISSING_FUNCTION:user_accessible_stores';
  END IF;
END;
$$;

ALTER TABLE public.brands
  ADD COLUMN IF NOT EXISTS management_model text NOT NULL DEFAULT 'store_managed',
  ADD COLUMN IF NOT EXISTS brand_manager_slots integer NOT NULL DEFAULT 1;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.brands'::regclass
      AND conname = 'brands_management_model_check'
  ) THEN
    ALTER TABLE public.brands ADD CONSTRAINT brands_management_model_check
      CHECK (management_model IN ('brand_centralized', 'store_managed'));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.brands'::regclass
      AND conname = 'brands_brand_manager_slots_check'
  ) THEN
    ALTER TABLE public.brands ADD CONSTRAINT brands_brand_manager_slots_check
      CHECK (brand_manager_slots BETWEEN 1 AND 20);
  END IF;
END;
$$;

ALTER TABLE public.restaurants
  ADD COLUMN IF NOT EXISTS short_code text;

CREATE UNIQUE INDEX IF NOT EXISTS restaurants_short_code_unique
  ON public.restaurants (upper(short_code))
  WHERE short_code IS NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.restaurants'::regclass
      AND conname = 'restaurants_short_code_check'
  ) THEN
    ALTER TABLE public.restaurants ADD CONSTRAINT restaurants_short_code_check
      CHECK (short_code IS NULL OR short_code ~ '^[A-Z0-9]{2,6}$');
  END IF;
END;
$$;

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS account_type text NOT NULL DEFAULT 'legacy_user',
  ADD COLUMN IF NOT EXISTS fixed_account_code text;

CREATE UNIQUE INDEX IF NOT EXISTS users_fixed_account_code_unique
  ON public.users (lower(fixed_account_code))
  WHERE fixed_account_code IS NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.users'::regclass
      AND conname = 'users_account_type_check'
  ) THEN
    ALTER TABLE public.users ADD CONSTRAINT users_account_type_check CHECK (
      account_type IN (
        'legacy_user', 'master', 'brand_manager', 'store_manager',
        'device_pos', 'device_tablet', 'device_kitchen', 'store_operator'
      )
    );
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.users'::regclass
      AND conname = 'users_fixed_account_code_check'
  ) THEN
    ALTER TABLE public.users ADD CONSTRAINT users_fixed_account_code_check CHECK (
      (account_type = 'legacy_user' AND fixed_account_code IS NULL)
      OR (
        account_type <> 'legacy_user'
        AND fixed_account_code IS NOT NULL
        AND fixed_account_code ~ '^[a-z][a-z0-9_]{1,31}$'
      )
    );
  END IF;

  ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;
  ALTER TABLE public.users ADD CONSTRAINT users_role_check CHECK (role IN (
    'super_admin', 'master_admin', 'brand_admin', 'store_admin', 'admin',
    'waiter', 'kitchen', 'cashier', 'photo_objet_master',
    'photo_objet_store_admin', 'photo_objet_store_operator'
  ));
END;
$$;

CREATE TABLE IF NOT EXISTS public.workforce_fixed_account_migration_state (
  user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE RESTRICT,
  original_is_active boolean NOT NULL,
  original_role text NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON TABLE public.workforce_fixed_account_migration_state
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.workforce_fixed_account_function_state (
  function_signature text PRIMARY KEY,
  original_definition text NOT NULL,
  definition_fingerprint text NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT workforce_fixed_account_function_state_fingerprint_check
    CHECK (definition_fingerprint = md5(original_definition))
);
REVOKE ALL ON TABLE public.workforce_fixed_account_function_state
  FROM PUBLIC, anon, authenticated, service_role;

INSERT INTO public.workforce_fixed_account_function_state(
  function_signature, original_definition, definition_fingerprint
)
SELECT
  'public.require_admin_actor_for_restaurant(uuid)',
  pg_get_functiondef('public.require_admin_actor_for_restaurant(uuid)'::regprocedure),
  md5(pg_get_functiondef('public.require_admin_actor_for_restaurant(uuid)'::regprocedure))
ON CONFLICT (function_signature) DO NOTHING;

CREATE OR REPLACE FUNCTION public.require_admin_actor_for_restaurant(
  p_store_id uuid
) RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED'; END IF;
  SELECT * INTO v_actor FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN (
    'admin', 'store_admin', 'brand_admin', 'super_admin', 'photo_objet_master'
  ) THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;
  IF v_actor.role = 'photo_objet_master' AND NOT EXISTS (
    SELECT 1 FROM public.restaurants r
    JOIN public.brands b ON b.id = r.brand_id
    WHERE r.id = p_store_id
      AND b.management_model = 'brand_centralized'
  ) THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;
  IF v_actor.role <> 'super_admin' AND NOT EXISTS (
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id)
    WHERE s.store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;
  RETURN v_actor;
END;
$$;

INSERT INTO public.workforce_fixed_account_migration_state (
  user_id, original_is_active, original_role
)
SELECT id, is_active, role
FROM public.users
WHERE role = 'photo_objet_store_admin'
ON CONFLICT (user_id) DO NOTHING;

UPDATE public.users
SET is_active = false
WHERE role = 'photo_objet_store_admin'
  AND is_active = true;

CREATE TABLE IF NOT EXISTS public.store_fixed_account_requirements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  account_code text NOT NULL,
  account_type text NOT NULL,
  role text NOT NULL,
  display_name text NOT NULL,
  scope text NOT NULL,
  provisioned_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT store_fixed_account_requirements_identity_unique
    UNIQUE (store_id, account_code),
  CONSTRAINT store_fixed_account_requirements_code_check
    CHECK (account_code ~ '^[a-z][a-z0-9_]{1,31}$'),
  CONSTRAINT store_fixed_account_requirements_type_check CHECK (
    account_type IN (
      'brand_manager', 'store_manager', 'device_pos', 'device_tablet',
      'device_kitchen', 'store_operator'
    )
  ),
  CONSTRAINT store_fixed_account_requirements_scope_check
    CHECK (scope IN ('brand', 'store')),
  CONSTRAINT store_fixed_account_requirements_role_check CHECK (role IN (
    'brand_admin', 'store_admin', 'cashier', 'kitchen',
    'photo_objet_master', 'photo_objet_store_operator'
  )),
  CONSTRAINT store_fixed_account_requirements_role_type_check CHECK (
    (account_type = 'brand_manager' AND role IN ('brand_admin', 'photo_objet_master') AND scope = 'brand')
    OR (account_type = 'store_manager' AND role = 'store_admin' AND scope = 'store')
    OR (account_type IN ('device_pos', 'device_tablet') AND role = 'cashier' AND scope = 'store')
    OR (account_type = 'device_kitchen' AND role = 'kitchen' AND scope = 'store')
    OR (account_type = 'store_operator' AND role = 'photo_objet_store_operator' AND scope = 'store')
  )
);

CREATE INDEX IF NOT EXISTS store_fixed_account_requirements_store_active_idx
  ON public.store_fixed_account_requirements(store_id, is_active);

CREATE TABLE IF NOT EXISTS public.store_employee_number_sequences (
  store_id uuid PRIMARY KEY REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  next_value bigint NOT NULL DEFAULT 1 CHECK (next_value > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE SEQUENCE IF NOT EXISTS public.store_employee_payment_profile_version_seq;

CREATE TABLE IF NOT EXISTS public.store_employees (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  employee_number text NOT NULL,
  full_name text NOT NULL,
  employment_role text NOT NULL DEFAULT 'part_timer',
  phone text,
  bank_account_number text,
  bank_account_holder text,
  is_active boolean NOT NULL DEFAULT true,
  payment_profile_version bigint NOT NULL
    DEFAULT nextval('public.store_employee_payment_profile_version_seq'),
  created_by_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  deactivated_by_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  deactivated_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT store_employees_store_number_unique UNIQUE (store_id, employee_number),
  CONSTRAINT store_employees_role_check
    CHECK (employment_role IN ('part_timer', 'full_time', 'manager')),
  CONSTRAINT store_employees_number_check
    CHECK (employee_number ~ '^[A-Z0-9]{2,6}[1-9][0-9]*$'),
  CONSTRAINT store_employees_name_check CHECK (length(btrim(full_name)) BETWEEN 1 AND 120)
);

CREATE UNIQUE INDEX IF NOT EXISTS store_employees_number_global_unique
  ON public.store_employees(upper(employee_number));
CREATE INDEX IF NOT EXISTS store_employees_store_active_idx
  ON public.store_employees(store_id, is_active, employee_number);

CREATE TABLE IF NOT EXISTS public.employee_office_sync_outbox (
  employee_id uuid NOT NULL REFERENCES public.store_employees(id) ON DELETE RESTRICT,
  profile_version bigint NOT NULL,
  changed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employee_id, profile_version)
);

REVOKE ALL ON TABLE public.store_employee_number_sequences,
  public.employee_office_sync_outbox FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON TABLE public.store_employees FROM service_role;
REVOKE ALL ON TABLE public.store_employees FROM anon, authenticated;
GRANT SELECT ON TABLE public.store_employees TO authenticated;
GRANT SELECT ON TABLE public.store_fixed_account_requirements TO authenticated;

ALTER TABLE public.attendance_logs
  ADD COLUMN IF NOT EXISTS employee_id uuid REFERENCES public.store_employees(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS recorded_by_user_id uuid REFERENCES public.users(id) ON DELETE SET NULL;
ALTER TABLE public.attendance_logs ALTER COLUMN user_id DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.attendance_logs'::regclass
      AND conname = 'attendance_logs_actor_check'
  ) THEN
    ALTER TABLE public.attendance_logs ADD CONSTRAINT attendance_logs_actor_check
      CHECK (user_id IS NOT NULL OR employee_id IS NOT NULL);
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS attendance_logs_employee_time_idx
  ON public.attendance_logs(employee_id, logged_at DESC)
  WHERE employee_id IS NOT NULL;

ALTER TABLE public.inventory_transactions
  ADD COLUMN IF NOT EXISTS performed_by_employee_id uuid
    REFERENCES public.store_employees(id) ON DELETE SET NULL;
ALTER TABLE public.inventory_physical_counts
  ADD COLUMN IF NOT EXISTS performed_by_employee_id uuid
    REFERENCES public.store_employees(id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.workforce_can_manage_store(p_store_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = true
      AND u.role IN (
        'super_admin', 'admin', 'store_admin', 'brand_admin',
        'photo_objet_master'
      )
      AND (
        u.role = 'super_admin'
        OR EXISTS (
          SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id = p_store_id
        )
      )
      AND (
        u.role <> 'photo_objet_master'
        OR EXISTS (
          SELECT 1 FROM public.restaurants r
          JOIN public.brands b ON b.id = r.brand_id
          WHERE r.id = p_store_id
            AND b.management_model = 'brand_centralized'
        )
      )
  );
$$;

CREATE OR REPLACE FUNCTION public.require_workforce_manager(p_store_id uuid)
RETURNS public.users
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;
  IF NOT FOUND OR NOT public.workforce_can_manage_store(p_store_id) THEN
    RAISE EXCEPTION 'WORKFORCE_MANAGEMENT_FORBIDDEN';
  END IF;
  RETURN v_actor;
END;
$$;

CREATE OR REPLACE FUNCTION public.store_employee_profile_outbox_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (
    NEW.phone IS DISTINCT FROM OLD.phone
    OR NEW.bank_account_number IS DISTINCT FROM OLD.bank_account_number
    OR NEW.bank_account_holder IS DISTINCT FROM OLD.bank_account_holder
    OR NEW.is_active IS DISTINCT FROM OLD.is_active
  ) THEN
    NEW.payment_profile_version := nextval('public.store_employee_payment_profile_version_seq');
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.store_employee_outbox_append_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.payment_profile_version IS DISTINCT FROM OLD.payment_profile_version THEN
    INSERT INTO public.employee_office_sync_outbox(employee_id, profile_version)
    VALUES (NEW.id, NEW.payment_profile_version)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS store_employee_profile_before_write ON public.store_employees;
CREATE TRIGGER store_employee_profile_before_write
BEFORE INSERT OR UPDATE ON public.store_employees
FOR EACH ROW EXECUTE FUNCTION public.store_employee_profile_outbox_trigger();

DROP TRIGGER IF EXISTS store_employee_outbox_after_write ON public.store_employees;
CREATE TRIGGER store_employee_outbox_after_write
AFTER INSERT OR UPDATE ON public.store_employees
FOR EACH ROW EXECUTE FUNCTION public.store_employee_outbox_append_trigger();

CREATE OR REPLACE FUNCTION public.create_store_employee(
  p_store_id uuid,
  p_full_name text,
  p_employment_role text DEFAULT 'part_timer',
  p_phone text DEFAULT NULL,
  p_bank_account_number text DEFAULT NULL,
  p_bank_account_holder text DEFAULT NULL
) RETURNS public.store_employees
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_short_code text;
  v_number bigint;
  v_employee public.store_employees%ROWTYPE;
BEGIN
  v_actor := public.require_workforce_manager(p_store_id);
  SELECT short_code INTO v_short_code
  FROM public.restaurants
  WHERE id = p_store_id AND is_active = true;
  IF v_short_code IS NULL THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_REQUIRED';
  END IF;
  IF p_employment_role NOT IN ('part_timer', 'full_time', 'manager') THEN
    RAISE EXCEPTION 'EMPLOYMENT_ROLE_INVALID';
  END IF;
  IF NULLIF(btrim(COALESCE(p_full_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_NAME_REQUIRED';
  END IF;

  INSERT INTO public.store_employee_number_sequences(store_id, next_value)
  VALUES (p_store_id, 2)
  ON CONFLICT (store_id) DO UPDATE SET
    next_value = public.store_employee_number_sequences.next_value + 1,
    updated_at = now()
  RETURNING next_value - 1 INTO v_number;

  INSERT INTO public.store_employees(
    store_id, employee_number, full_name, employment_role, phone,
    bank_account_number, bank_account_holder, created_by_user_id
  ) VALUES (
    p_store_id, upper(v_short_code) || v_number::text, btrim(p_full_name),
    p_employment_role, NULLIF(btrim(COALESCE(p_phone, '')), ''),
    NULLIF(btrim(COALESCE(p_bank_account_number, '')), ''),
    NULLIF(btrim(COALESCE(p_bank_account_holder, '')), ''), v_actor.id
  ) RETURNING * INTO v_employee;

  RETURN v_employee;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_store_employee(
  p_store_id uuid,
  p_employee_id uuid,
  p_full_name text,
  p_employment_role text,
  p_phone text DEFAULT NULL,
  p_bank_account_number text DEFAULT NULL,
  p_bank_account_holder text DEFAULT NULL
) RETURNS public.store_employees
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_employee public.store_employees%ROWTYPE;
BEGIN
  PERFORM public.require_workforce_manager(p_store_id);
  IF p_employment_role NOT IN ('part_timer', 'full_time', 'manager') THEN
    RAISE EXCEPTION 'EMPLOYMENT_ROLE_INVALID';
  END IF;
  UPDATE public.store_employees SET
    full_name = btrim(p_full_name),
    employment_role = p_employment_role,
    phone = NULLIF(btrim(COALESCE(p_phone, '')), ''),
    bank_account_number = NULLIF(btrim(COALESCE(p_bank_account_number, '')), ''),
    bank_account_holder = NULLIF(btrim(COALESCE(p_bank_account_holder, '')), '')
  WHERE id = p_employee_id AND store_id = p_store_id
  RETURNING * INTO v_employee;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
  RETURN v_employee;
END;
$$;

CREATE OR REPLACE FUNCTION public.deactivate_store_employee(
  p_store_id uuid,
  p_employee_id uuid
) RETURNS public.store_employees
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_employee public.store_employees%ROWTYPE;
BEGIN
  v_actor := public.require_workforce_manager(p_store_id);
  UPDATE public.store_employees SET
    is_active = false,
    deactivated_at = COALESCE(deactivated_at, now()),
    deactivated_by_user_id = COALESCE(deactivated_by_user_id, v_actor.id)
  WHERE id = p_employee_id AND store_id = p_store_id
  RETURNING * INTO v_employee;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
  RETURN v_employee;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_employee_attendance(
  p_store_id uuid,
  p_employee_number text,
  p_type text
) RETURNS public.attendance_logs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_employee public.store_employees%ROWTYPE;
  v_log public.attendance_logs%ROWTYPE;
BEGIN
  SELECT * INTO v_actor FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin',
    'photo_objet_master', 'photo_objet_store_operator'
  ) OR (
    v_actor.role <> 'super_admin'
    AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = p_store_id
    )
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_ENTRY_FORBIDDEN';
  END IF;
  IF p_type NOT IN ('clock_in', 'clock_out') THEN
    RAISE EXCEPTION 'ATTENDANCE_TYPE_INVALID';
  END IF;
  SELECT * INTO v_employee FROM public.store_employees
  WHERE store_id = p_store_id
    AND upper(employee_number) = upper(btrim(p_employee_number))
    AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NUMBER_NOT_FOUND'; END IF;

  INSERT INTO public.attendance_logs(
    restaurant_id, user_id, employee_id, type, recorded_by_user_id
  ) VALUES (p_store_id, NULL, v_employee.id, p_type, v_actor.id)
  RETURNING * INTO v_log;
  RETURN v_log;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_employee_inventory_adjustment(
  p_store_id uuid,
  p_employee_number text,
  p_ingredient_id uuid,
  p_transaction_type text,
  p_quantity_g numeric,
  p_note text DEFAULT NULL
) RETURNS public.inventory_transactions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_employee public.store_employees%ROWTYPE;
  v_item public.inventory_items%ROWTYPE;
  v_old_stock numeric;
  v_new_stock numeric;
  v_transaction_quantity numeric;
  v_transaction public.inventory_transactions%ROWTYPE;
BEGIN
  SELECT * INTO v_actor FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN (
    'photo_objet_store_operator', 'photo_objet_master', 'store_admin',
    'brand_admin', 'super_admin'
  ) OR (
    v_actor.role <> 'super_admin'
    AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = p_store_id
    )
  ) THEN
    RAISE EXCEPTION 'EMPLOYEE_INVENTORY_FORBIDDEN';
  END IF;
  IF p_transaction_type NOT IN ('restock', 'adjust', 'waste')
     OR p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'EMPLOYEE_INVENTORY_INPUT_INVALID';
  END IF;
  SELECT * INTO v_employee FROM public.store_employees
  WHERE store_id = p_store_id
    AND upper(employee_number) = upper(btrim(p_employee_number))
    AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NUMBER_NOT_FOUND'; END IF;

  SELECT * INTO v_item FROM public.inventory_items
  WHERE id = p_ingredient_id AND restaurant_id = p_store_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_INVENTORY_ITEM_NOT_FOUND'; END IF;

  v_old_stock := COALESCE(v_item.current_stock, 0);
  IF p_transaction_type = 'restock' THEN
    v_new_stock := v_old_stock + p_quantity_g;
    v_transaction_quantity := p_quantity_g;
  ELSIF p_transaction_type = 'waste' THEN
    v_new_stock := v_old_stock - p_quantity_g;
    v_transaction_quantity := -p_quantity_g;
  ELSE
    v_new_stock := p_quantity_g;
    v_transaction_quantity := p_quantity_g - v_old_stock;
  END IF;

  UPDATE public.inventory_items
  SET current_stock = v_new_stock, updated_at = now()
  WHERE id = p_ingredient_id AND restaurant_id = p_store_id;

  INSERT INTO public.inventory_transactions(
    restaurant_id, ingredient_id, transaction_type, quantity_g,
    reference_type, note, created_by, performed_by_employee_id
  ) VALUES (
    p_store_id, p_ingredient_id, p_transaction_type, v_transaction_quantity,
    'employee_number', NULLIF(btrim(COALESCE(p_note, '')), ''),
    auth.uid(), v_employee.id
  ) RETURNING * INTO v_transaction;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'employee_inventory_adjusted', 'inventory_items', p_ingredient_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'employee_id', v_employee.id,
      'employee_number', v_employee.employee_number,
      'transaction_type', p_transaction_type,
      'old_stock', v_old_stock,
      'new_stock', v_new_stock,
      'quantity_g', v_transaction_quantity
    )
  );
  RETURN v_transaction;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_configure_store_workforce(
  p_store_id uuid,
  p_short_code text,
  p_management_model text,
  p_brand_manager_slots integer,
  p_account_templates jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_brand_id uuid;
  v_existing_short_code text;
  v_item jsonb;
  v_count integer := 0;
BEGIN
  v_actor := public.require_workforce_manager(p_store_id);
  SELECT brand_id, short_code INTO v_brand_id, v_existing_short_code
  FROM public.restaurants WHERE id = p_store_id;
  IF v_brand_id IS NULL THEN RAISE EXCEPTION 'STORE_BRAND_REQUIRED'; END IF;
  IF upper(btrim(p_short_code)) !~ '^[A-Z0-9]{2,6}$' THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_INVALID';
  END IF;
  IF p_management_model NOT IN ('brand_centralized', 'store_managed') THEN
    RAISE EXCEPTION 'MANAGEMENT_MODEL_INVALID';
  END IF;
  IF p_brand_manager_slots NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'BRAND_MANAGER_SLOTS_INVALID';
  END IF;
  IF jsonb_typeof(p_account_templates) <> 'array' OR jsonb_array_length(p_account_templates) = 0 THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATES_REQUIRED';
  END IF;
  IF jsonb_array_length(p_account_templates) > 50 THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATE_LIMIT';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_account_templates) item(value)
    GROUP BY lower(value->>'account_code') HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATE_DUPLICATE_CODE';
  END IF;
  IF (
    SELECT count(*) FROM jsonb_array_elements(p_account_templates) item(value)
    WHERE value->>'account_type' = 'brand_manager'
  ) NOT IN (0, p_brand_manager_slots) THEN
    RAISE EXCEPTION 'BRAND_MANAGER_TEMPLATE_COUNT_INVALID';
  END IF;
  IF v_existing_short_code IS NOT NULL
     AND v_existing_short_code <> upper(btrim(p_short_code))
     AND (
       EXISTS (SELECT 1 FROM public.store_employees WHERE store_id = p_store_id)
       OR EXISTS (
         SELECT 1 FROM public.store_fixed_account_requirements
         WHERE store_id = p_store_id AND provisioned_user_id IS NOT NULL
       )
     ) THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_IMMUTABLE_AFTER_USE';
  END IF;

  UPDATE public.restaurants SET short_code = upper(btrim(p_short_code))
  WHERE id = p_store_id;
  UPDATE public.brands SET
    management_model = p_management_model,
    brand_manager_slots = p_brand_manager_slots
  WHERE id = v_brand_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_account_templates) LOOP
    IF COALESCE(v_item->>'account_code', '') !~ '^[a-z][a-z0-9_]{1,31}$'
       OR COALESCE(v_item->>'scope', '') NOT IN ('brand', 'store')
       OR COALESCE(v_item->>'account_type', '') NOT IN (
         'brand_manager', 'store_manager', 'device_pos', 'device_tablet',
         'device_kitchen', 'store_operator'
       )
       OR COALESCE(v_item->>'role', '') NOT IN (
         'brand_admin', 'store_admin', 'cashier', 'kitchen',
         'photo_objet_master', 'photo_objet_store_operator'
       )
       OR NULLIF(btrim(COALESCE(v_item->>'display_name', '')), '') IS NULL THEN
      RAISE EXCEPTION 'ACCOUNT_TEMPLATE_INVALID';
    END IF;
    IF (v_item->>'account_type') = 'brand_manager'
       AND v_actor.role <> 'super_admin' THEN
      RAISE EXCEPTION 'BRAND_MANAGER_TEMPLATE_FORBIDDEN';
    END IF;
    IF (v_item->>'account_type') = 'store_manager'
       AND v_actor.role NOT IN ('super_admin', 'brand_admin') THEN
      RAISE EXCEPTION 'STORE_MANAGER_TEMPLATE_FORBIDDEN';
    END IF;
    IF p_management_model = 'brand_centralized'
       AND (v_item->>'account_type') = 'store_manager' THEN
      RAISE EXCEPTION 'CENTRALIZED_STORE_MANAGER_FORBIDDEN';
    END IF;
    IF (v_item->>'account_type') IN (
      'device_pos', 'device_tablet', 'device_kitchen', 'store_operator'
    ) AND (v_item->>'account_code') NOT LIKE lower(upper(btrim(p_short_code))) || '\_%' ESCAPE '\' THEN
      RAISE EXCEPTION 'STORE_ACCOUNT_CODE_PREFIX_INVALID';
    END IF;
    INSERT INTO public.store_fixed_account_requirements(
      store_id, account_code, account_type, role, display_name, scope
    ) VALUES (
      p_store_id, v_item->>'account_code', v_item->>'account_type',
      v_item->>'role', btrim(v_item->>'display_name'), v_item->>'scope'
    ) ON CONFLICT (store_id, account_code) DO UPDATE SET
      account_type = EXCLUDED.account_type,
      role = EXCLUDED.role,
      display_name = EXCLUDED.display_name,
      scope = EXCLUDED.scope,
      is_active = true,
      updated_at = now();
    v_count := v_count + 1;
  END LOOP;
  UPDATE public.store_fixed_account_requirements q SET
    is_active = false,
    updated_at = now()
  WHERE q.store_id = p_store_id
    AND q.provisioned_user_id IS NULL
    AND q.is_active = true
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_account_templates) item(value)
      WHERE lower(value->>'account_code') = lower(q.account_code)
    );
  RETURN jsonb_build_object(
    'configured', true,
    'store_id', p_store_id,
    'short_code', upper(btrim(p_short_code)),
    'management_model', p_management_model,
    'template_count', v_count
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_get_store_workforce_readiness(p_store_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_short_code text;
  v_management_model text;
  v_required jsonb;
  v_missing jsonb;
  v_active_employees integer;
BEGIN
  PERFORM public.require_workforce_manager(p_store_id);
  SELECT r.short_code, b.management_model
  INTO v_short_code, v_management_model
  FROM public.restaurants r JOIN public.brands b ON b.id = r.brand_id
  WHERE r.id = p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'STORE_NOT_FOUND'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'requirement_id', q.id,
    'account_code', q.account_code,
    'email', q.account_code || '@globos.world',
    'account_type', q.account_type,
    'role', q.role,
    'display_name', q.display_name,
    'scope', q.scope,
    'provisioned', u.id IS NOT NULL AND u.is_active = true
  ) ORDER BY q.account_code), '[]'::jsonb),
  COALESCE(jsonb_agg(jsonb_build_object(
    'requirement_id', q.id,
    'account_code', q.account_code,
    'email', q.account_code || '@globos.world'
  ) ORDER BY q.account_code) FILTER (WHERE u.id IS NULL OR u.is_active = false), '[]'::jsonb)
  INTO v_required, v_missing
  FROM public.store_fixed_account_requirements q
  LEFT JOIN public.users u
    ON lower(u.fixed_account_code) = lower(q.account_code)
   AND u.account_type = q.account_type
  WHERE q.store_id = p_store_id AND q.is_active = true;

  SELECT count(*) INTO v_active_employees
  FROM public.store_employees WHERE store_id = p_store_id AND is_active = true;

  RETURN jsonb_build_object(
    'short_code', v_short_code,
    'management_model', v_management_model,
    'account_templates_configured', jsonb_array_length(v_required) > 0,
    'accounts_ready', jsonb_array_length(v_required) > 0 AND jsonb_array_length(v_missing) = 0,
    'employees_active', v_active_employees,
    'required_accounts', v_required,
    'missing_accounts', v_missing
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.office_list_employee_payment_profiles(
  p_after_version bigint DEFAULT 0,
  p_limit integer DEFAULT 500
) RETURNS TABLE (
  pos_employee_id uuid,
  pos_store_id uuid,
  profile_version bigint,
  phone text,
  bank_account_number text,
  bank_account_holder text,
  is_active boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  IF COALESCE(auth.jwt()->>'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'OFFICE_PAYMENT_PROFILE_SYNC_FORBIDDEN';
  END IF;
  IF p_after_version < 0 OR p_limit NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'OFFICE_PAYMENT_PROFILE_SYNC_INPUT_INVALID';
  END IF;
  RETURN QUERY
  SELECT e.id, e.store_id, e.payment_profile_version, e.phone,
    e.bank_account_number, e.bank_account_holder, e.is_active
  FROM public.store_employees e
  WHERE e.payment_profile_version > p_after_version
  ORDER BY e.payment_profile_version, e.id
  LIMIT p_limit;
END;
$$;

ALTER TABLE public.store_employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_fixed_account_requirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employee_office_sync_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_employee_number_sequences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS store_employees_manager_read ON public.store_employees;
CREATE POLICY store_employees_manager_read ON public.store_employees
  FOR SELECT TO authenticated
  USING (public.workforce_can_manage_store(store_id));

DROP POLICY IF EXISTS fixed_account_requirements_manager_read
  ON public.store_fixed_account_requirements;
CREATE POLICY fixed_account_requirements_manager_read
  ON public.store_fixed_account_requirements
  FOR SELECT TO authenticated
  USING (public.workforce_can_manage_store(store_id));

REVOKE ALL ON FUNCTION public.workforce_can_manage_store(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.require_workforce_manager(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.store_employee_profile_outbox_trigger()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.store_employee_outbox_append_trigger()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_store_employee(uuid, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.update_store_employee(uuid, uuid, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.deactivate_store_employee(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_employee_attendance(uuid, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_employee_inventory_adjustment(uuid, text, uuid, text, numeric, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_configure_store_workforce(uuid, text, text, integer, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_get_store_workforce_readiness(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.office_list_employee_payment_profiles(bigint, integer)
  FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.workforce_can_manage_store(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_store_employee(uuid, text, text, text, text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_store_employee(uuid, uuid, text, text, text, text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_store_employee(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_employee_attendance(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_employee_inventory_adjustment(uuid, text, uuid, text, numeric, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_configure_store_workforce(uuid, text, text, integer, jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_get_store_workforce_readiness(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.office_list_employee_payment_profiles(bigint, integer)
  TO service_role;

COMMENT ON TABLE public.store_employees IS
  'Auth-less store employee directory. Employee numbers are server-generated, monotonic, never reassigned, and rows are soft-deactivated.';
COMMENT ON FUNCTION public.office_list_employee_payment_profiles(bigint, integer) IS
  'Service-role allowlist for Office payment-profile sync. Deliberately excludes employee name, role, and every attendance field.';

COMMIT;
