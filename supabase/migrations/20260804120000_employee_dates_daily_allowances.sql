BEGIN;

ALTER TABLE public.store_employees
  ADD COLUMN IF NOT EXISTS probation_start_date date,
  ADD COLUMN IF NOT EXISTS employment_start_date date;

ALTER TABLE public.store_employees
  DROP CONSTRAINT IF EXISTS store_employees_employment_dates_check;
ALTER TABLE public.store_employees
  ADD CONSTRAINT store_employees_employment_dates_check CHECK (
    (employment_role = 'full_time'
      AND (
        probation_start_date IS NULL
        OR employment_start_date IS NULL
        OR employment_start_date >= probation_start_date
      ))
    OR (employment_role IN ('part_timer', 'manager')
      AND probation_start_date IS NULL)
  );

CREATE TABLE IF NOT EXISTS public.employee_daily_allowances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  employee_id uuid NOT NULL REFERENCES public.store_employees(id) ON DELETE RESTRICT,
  work_date date NOT NULL,
  is_split_shift boolean NOT NULL DEFAULT false,
  meal_allowance_amount numeric(14,2) NOT NULL DEFAULT 0
    CHECK (meal_allowance_amount >= 0),
  parking_allowance_amount numeric(14,2) NOT NULL DEFAULT 0
    CHECK (parking_allowance_amount >= 0),
  note text,
  recorded_by_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_daily_allowances_store_employee_date_unique
    UNIQUE (store_id, employee_id, work_date)
);

CREATE INDEX IF NOT EXISTS employee_daily_allowances_payroll_idx
  ON public.employee_daily_allowances(store_id, work_date, employee_id);

ALTER TABLE public.employee_daily_allowances ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employee_daily_allowances_manager_read
  ON public.employee_daily_allowances;
CREATE POLICY employee_daily_allowances_manager_read
ON public.employee_daily_allowances
FOR SELECT TO authenticated
USING (public.workforce_can_manage_store(store_id));

REVOKE ALL ON TABLE public.employee_daily_allowances
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.employee_daily_allowances TO authenticated;

CREATE OR REPLACE FUNCTION public.create_store_employee_with_dates(
  p_store_id uuid,
  p_full_name text,
  p_employment_role text,
  p_phone text,
  p_bank_account_number text,
  p_bank_account_holder text,
  p_bank_name text,
  p_probation_start_date date,
  p_employment_start_date date
) RETURNS public.store_employees
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_employee public.store_employees%ROWTYPE;
BEGIN
  IF p_employment_role NOT IN ('part_timer', 'full_time', 'manager') THEN
    RAISE EXCEPTION 'EMPLOYMENT_ROLE_INVALID';
  END IF;
  IF p_employment_role = 'full_time'
     AND p_probation_start_date IS NOT NULL
     AND p_employment_start_date IS NOT NULL
     AND p_employment_start_date < p_probation_start_date THEN
    RAISE EXCEPTION 'EMPLOYMENT_DATE_ORDER_INVALID';
  END IF;
  IF p_employment_role IN ('part_timer', 'manager')
     AND p_probation_start_date IS NOT NULL THEN
    RAISE EXCEPTION 'PROBATION_DATE_ROLE_INVALID';
  END IF;

  v_employee := public.create_store_employee(
    p_store_id,
    p_full_name,
    p_employment_role,
    p_phone,
    p_bank_account_number,
    p_bank_account_holder,
    p_bank_name
  );

  UPDATE public.store_employees
  SET probation_start_date = p_probation_start_date,
      employment_start_date = p_employment_start_date,
      updated_at = now()
  WHERE id = v_employee.id
  RETURNING * INTO v_employee;

  RETURN v_employee;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_store_employee_with_dates(
  p_store_id uuid,
  p_employee_id uuid,
  p_full_name text,
  p_employment_role text,
  p_phone text,
  p_bank_account_number text,
  p_bank_account_holder text,
  p_bank_name text,
  p_probation_start_date date,
  p_employment_start_date date
) RETURNS public.store_employees
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_employee public.store_employees%ROWTYPE;
BEGIN
  IF p_employment_role NOT IN ('part_timer', 'full_time', 'manager') THEN
    RAISE EXCEPTION 'EMPLOYMENT_ROLE_INVALID';
  END IF;
  IF p_employment_role = 'full_time'
     AND p_probation_start_date IS NOT NULL
     AND p_employment_start_date IS NOT NULL
     AND p_employment_start_date < p_probation_start_date THEN
    RAISE EXCEPTION 'EMPLOYMENT_DATE_ORDER_INVALID';
  END IF;
  IF p_employment_role IN ('part_timer', 'manager')
     AND p_probation_start_date IS NOT NULL THEN
    RAISE EXCEPTION 'PROBATION_DATE_ROLE_INVALID';
  END IF;

  -- A full-time employee can be changed to another role. Clear the old
  -- probation date before the legacy updater changes employment_role, or the
  -- role/date constraint would reject the valid transition mid-function.
  PERFORM public.require_workforce_manager(p_store_id);
  IF p_employment_role <> 'full_time' THEN
    UPDATE public.store_employees
    SET probation_start_date = NULL,
        updated_at = now()
    WHERE id = p_employee_id
      AND store_id = p_store_id;
  END IF;

  v_employee := public.update_store_employee(
    p_store_id,
    p_employee_id,
    p_full_name,
    p_employment_role,
    p_phone,
    p_bank_account_number,
    p_bank_account_holder,
    p_bank_name
  );

  UPDATE public.store_employees
  SET probation_start_date = p_probation_start_date,
      employment_start_date = p_employment_start_date,
      updated_at = now()
  WHERE id = v_employee.id
  RETURNING * INTO v_employee;

  RETURN v_employee;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_store_part_timer_with_pay_rule_and_dates(
  p_store_id uuid,
  p_full_name text,
  p_phone text,
  p_bank_name text,
  p_bank_account_number text,
  p_bank_account_holder text,
  p_hourly_rate numeric,
  p_work_start_date date,
  p_scheduled_start time DEFAULT '09:00',
  p_night_start time DEFAULT '22:00',
  p_night_multiplier numeric DEFAULT 1.3,
  p_holiday_multiplier numeric DEFAULT 3,
  p_late_threshold_minutes integer DEFAULT 60,
  p_late_review_hourly_multiplier numeric DEFAULT 2
) RETURNS public.store_employees
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_employee public.store_employees%ROWTYPE;
BEGIN
  v_employee := public.create_store_employee_with_dates(
    p_store_id,
    p_full_name,
    'part_timer',
    p_phone,
    p_bank_account_number,
    p_bank_account_holder,
    p_bank_name,
    NULL,
    p_work_start_date
  );

  PERFORM public.upsert_employee_hourly_pay_rule(
    p_store_id,
    v_employee.id,
    p_hourly_rate,
    p_scheduled_start,
    p_night_start,
    p_night_multiplier,
    p_holiday_multiplier,
    true,
    p_late_threshold_minutes,
    p_late_review_hourly_multiplier
  );
  RETURN v_employee;
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_employee_daily_allowance(
  p_store_id uuid,
  p_employee_id uuid,
  p_work_date date,
  p_is_split_shift boolean DEFAULT false,
  p_parking_allowance_amount numeric DEFAULT 0,
  p_note text DEFAULT NULL
) RETURNS public.employee_daily_allowances
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_employee public.store_employees%ROWTYPE;
  v_has_completed_attendance boolean;
  v_meal_allowance numeric(14,2) := 0;
  v_allowance public.employee_daily_allowances%ROWTYPE;
BEGIN
  v_actor := public.require_workforce_manager(p_store_id);
  IF p_work_date IS NULL OR COALESCE(p_parking_allowance_amount, 0) < 0 THEN
    RAISE EXCEPTION 'EMPLOYEE_ALLOWANCE_INPUT_INVALID';
  END IF;

  SELECT * INTO v_employee
  FROM public.store_employees
  WHERE id = p_employee_id
    AND store_id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND';
  END IF;
  IF v_employee.employment_role NOT IN ('part_timer', 'full_time') THEN
    RAISE EXCEPTION 'EMPLOYEE_ALLOWANCE_ROLE_INVALID';
  END IF;
  IF v_employee.employment_role <> 'part_timer'
     AND COALESCE(p_is_split_shift, false) THEN
    RAISE EXCEPTION 'SPLIT_SHIFT_PART_TIMER_ONLY';
  END IF;

  SELECT
    EXISTS (
      SELECT 1 FROM public.attendance_logs log
      WHERE log.restaurant_id = p_store_id
        AND log.employee_id = p_employee_id
        AND log.type = 'clock_in'
        AND (log.logged_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date = p_work_date
    )
    AND EXISTS (
      SELECT 1 FROM public.attendance_logs log
      WHERE log.restaurant_id = p_store_id
        AND log.employee_id = p_employee_id
        AND log.type = 'clock_out'
        AND (log.logged_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date = p_work_date
    )
  INTO v_has_completed_attendance;

  IF COALESCE(p_is_split_shift, false) AND NOT v_has_completed_attendance THEN
    RAISE EXCEPTION 'SPLIT_SHIFT_ATTENDANCE_INCOMPLETE';
  END IF;
  IF v_employee.employment_role = 'part_timer'
     AND COALESCE(p_is_split_shift, false)
     AND v_has_completed_attendance THEN
    v_meal_allowance := 25000;
  END IF;

  INSERT INTO public.employee_daily_allowances(
    store_id,
    employee_id,
    work_date,
    is_split_shift,
    meal_allowance_amount,
    parking_allowance_amount,
    note,
    recorded_by_user_id
  ) VALUES (
    p_store_id,
    p_employee_id,
    p_work_date,
    COALESCE(p_is_split_shift, false),
    v_meal_allowance,
    COALESCE(p_parking_allowance_amount, 0),
    NULLIF(btrim(COALESCE(p_note, '')), ''),
    v_actor.id
  )
  ON CONFLICT (store_id, employee_id, work_date) DO UPDATE SET
    is_split_shift = EXCLUDED.is_split_shift,
    meal_allowance_amount = EXCLUDED.meal_allowance_amount,
    parking_allowance_amount = EXCLUDED.parking_allowance_amount,
    note = EXCLUDED.note,
    recorded_by_user_id = EXCLUDED.recorded_by_user_id,
    updated_at = now()
  RETURNING * INTO v_allowance;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'upsert_employee_daily_allowance',
    'employee_daily_allowances',
    v_allowance.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'employee_id', p_employee_id,
      'work_date', p_work_date,
      'is_split_shift', v_allowance.is_split_shift,
      'meal_allowance_amount', v_allowance.meal_allowance_amount,
      'parking_allowance_amount', v_allowance.parking_allowance_amount
    )
  );

  RETURN v_allowance;
END;
$$;

ALTER TABLE public.inventory_items
  DROP CONSTRAINT IF EXISTS inventory_items_unit_check;
ALTER TABLE public.inventory_items
  ADD CONSTRAINT inventory_items_unit_check
  CHECK (unit IN ('g', 'ml', 'ea', 'box'));

CREATE OR REPLACE FUNCTION public.save_photo_objet_daily_inventory_item_with_unit(
  p_store_id uuid,
  p_item_id uuid,
  p_name text,
  p_current_stock numeric,
  p_unit text,
  p_count_date date,
  p_note text DEFAULT NULL
) RETURNS public.inventory_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_item public.inventory_items%ROWTYPE;
  v_unit text := lower(btrim(COALESCE(p_unit, '')));
BEGIN
  IF v_unit NOT IN ('g', 'ml', 'ea', 'box') THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_UNIT_INVALID';
  END IF;

  v_item := public.save_photo_objet_daily_inventory_item(
    p_store_id,
    p_item_id,
    p_name,
    p_current_stock,
    p_count_date,
    p_note
  );

  UPDATE public.inventory_items
  SET unit = v_unit,
      updated_at = now()
  WHERE id = v_item.id
    AND restaurant_id = p_store_id
  RETURNING * INTO v_item;

  RETURN v_item;
END;
$$;

REVOKE ALL ON FUNCTION public.create_store_employee_with_dates(
  uuid, text, text, text, text, text, text, date, date
) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.update_store_employee_with_dates(
  uuid, uuid, text, text, text, text, text, text, date, date
) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.create_store_part_timer_with_pay_rule_and_dates(
  uuid, text, text, text, text, text, numeric, date,
  time, time, numeric, numeric, integer, numeric
) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.upsert_employee_daily_allowance(
  uuid, uuid, date, boolean, numeric, text
) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.save_photo_objet_daily_inventory_item_with_unit(
  uuid, uuid, text, numeric, text, date, text
) FROM PUBLIC, anon, service_role;

GRANT EXECUTE ON FUNCTION public.create_store_employee_with_dates(
  uuid, text, text, text, text, text, text, date, date
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_store_employee_with_dates(
  uuid, uuid, text, text, text, text, text, text, date, date
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_store_part_timer_with_pay_rule_and_dates(
  uuid, text, text, text, text, text, numeric, date,
  time, time, numeric, numeric, integer, numeric
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_employee_daily_allowance(
  uuid, uuid, date, boolean, numeric, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_photo_objet_daily_inventory_item_with_unit(
  uuid, uuid, text, numeric, text, date, text
) TO authenticated;

COMMENT ON COLUMN public.store_employees.probation_start_date IS
  'Full-time employee probation start date. Null for part-timers and managers.';
COMMENT ON COLUMN public.store_employees.employment_start_date IS
  'Official contract start date for full-time employees and work start date for part-timers.';
COMMENT ON TABLE public.employee_daily_allowances IS
  'Audited daily meal and parking allowances. Split-shift meal allowance is fixed at 25,000 VND for part-timers with completed attendance.';

COMMIT;
