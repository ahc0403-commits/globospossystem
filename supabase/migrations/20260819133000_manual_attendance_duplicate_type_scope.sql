BEGIN;

CREATE OR REPLACE FUNCTION public.admin_record_employee_attendance(
  p_store_id uuid,
  p_employee_id uuid,
  p_type text,
  p_logged_at timestamptz,
  p_reason text,
  p_manager_pin text
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
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) OR (
    v_actor.role <> 'super_admin'
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id = p_store_id
    )
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_MANUAL_ENTRY_FORBIDDEN';
  END IF;

  PERFORM public.verify_discount_manager_pin_or_raise(
    p_store_id,
    p_manager_pin,
    'attendance_manual_entry'
  );

  IF p_type NOT IN ('clock_in', 'clock_out') THEN
    RAISE EXCEPTION 'ATTENDANCE_TYPE_INVALID';
  END IF;
  IF p_logged_at IS NULL OR p_logged_at > now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'ATTENDANCE_MANUAL_TIME_INVALID';
  END IF;
  IF length(btrim(COALESCE(p_reason, ''))) NOT BETWEEN 3 AND 500 THEN
    RAISE EXCEPTION 'ATTENDANCE_MANUAL_REASON_REQUIRED';
  END IF;

  SELECT * INTO v_employee
  FROM public.store_employees
  WHERE id = p_employee_id
    AND store_id = p_store_id
    AND is_active = true
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.attendance_logs al
    WHERE al.restaurant_id = p_store_id
      AND al.employee_id = p_employee_id
      AND al.type = p_type
      AND al.logged_at = p_logged_at
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_MANUAL_TIME_DUPLICATE';
  END IF;

  INSERT INTO public.attendance_logs(
    restaurant_id,
    user_id,
    employee_id,
    type,
    logged_at,
    recorded_by_user_id
  ) VALUES (
    p_store_id,
    NULL,
    p_employee_id,
    p_type,
    p_logged_at,
    v_actor.id
  )
  RETURNING * INTO v_log;

  INSERT INTO public.audit_logs(
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    auth.uid(),
    'attendance_manual_entry',
    'attendance_logs',
    v_log.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'employee_id', p_employee_id,
      'employee_number', v_employee.employee_number,
      'attendance_type', p_type,
      'logged_at', p_logged_at,
      'reason', btrim(p_reason)
    )
  );

  RETURN v_log;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_record_employee_attendance(
  uuid, uuid, text, timestamptz, text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_record_employee_attendance(
  uuid, uuid, text, timestamptz, text, text
) TO authenticated, service_role;

COMMENT ON FUNCTION public.admin_record_employee_attendance(
  uuid, uuid, text, timestamptz, text, text
) IS 'Allows scoped managers to backfill attendance in any order, rejecting only a duplicate event type at the same timestamp.';

COMMIT;
