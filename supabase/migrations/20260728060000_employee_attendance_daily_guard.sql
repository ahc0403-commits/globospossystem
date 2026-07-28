-- Enforce one ordered clock-in/clock-out pair per employee shift.
-- The employee row lock serializes concurrent kiosk requests for that person,
-- so validation and insert remain atomic across devices. A shift may close
-- after midnight, while a second clock-in on the same Vietnam date is blocked.
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
  v_business_date date;
  v_last_type text;
  v_has_clock_in_today boolean := false;
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
    AND is_active = true
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NUMBER_NOT_FOUND'; END IF;

  v_business_date := (statement_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
  SELECT al.type
  INTO v_last_type
  FROM public.attendance_logs al
  WHERE al.restaurant_id = p_store_id
    AND al.employee_id = v_employee.id
  ORDER BY al.logged_at DESC, al.created_at DESC
  LIMIT 1;

  SELECT EXISTS (
    SELECT 1
    FROM public.attendance_logs al
    WHERE al.restaurant_id = p_store_id
      AND al.employee_id = v_employee.id
      AND al.type = 'clock_in'
      AND (al.logged_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date =
        v_business_date
  ) INTO v_has_clock_in_today;

  IF p_type = 'clock_in' THEN
    IF v_last_type = 'clock_in' OR v_has_clock_in_today THEN
      RAISE EXCEPTION 'ATTENDANCE_ALREADY_CLOCKED_IN_TODAY';
    END IF;
  ELSE
    IF v_last_type = 'clock_out' THEN
      RAISE EXCEPTION 'ATTENDANCE_ALREADY_CLOCKED_OUT_TODAY';
    END IF;
    IF v_last_type IS DISTINCT FROM 'clock_in' THEN
      RAISE EXCEPTION 'ATTENDANCE_CLOCK_IN_REQUIRED';
    END IF;
  END IF;

  INSERT INTO public.attendance_logs(
    restaurant_id, user_id, employee_id, type, recorded_by_user_id
  ) VALUES (p_store_id, NULL, v_employee.id, p_type, v_actor.id)
  RETURNING * INTO v_log;

  RETURN v_log;
END;
$$;

COMMENT ON FUNCTION public.record_employee_attendance(uuid, text, text)
IS 'Atomically records one ordered clock-in/out shift, blocks repeated taps and second same-day clock-in, and permits overnight clock-out.';
