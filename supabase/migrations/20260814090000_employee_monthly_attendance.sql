BEGIN;

CREATE OR REPLACE FUNCTION public.get_employee_attendance_logs(
  p_store_id uuid,
  p_employee_id uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_limit integer DEFAULT 500
) RETURNS TABLE (
  id uuid,
  restaurant_id uuid,
  user_id uuid,
  employee_id uuid,
  type text,
  photo_url text,
  photo_thumbnail_url text,
  logged_at timestamptz,
  created_at timestamptz,
  person_name text,
  person_role text,
  employee_number text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_employee public.store_employees%ROWTYPE;
BEGIN
  SELECT actor.*
  INTO v_actor
  FROM public.users actor
  WHERE actor.auth_id = auth.uid()
    AND actor.is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'admin',
    'store_admin',
    'brand_admin',
    'super_admin',
    'photo_objet_master',
    'photo_objet_store_admin',
    'photo_objet_store_operator'
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_VIEW_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL
     OR p_employee_id IS NULL
     OR p_from IS NULL
     OR p_to IS NULL
     OR p_to <= p_from
     OR p_limit NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'ATTENDANCE_QUERY_INVALID';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ATTENDANCE_VIEW_FORBIDDEN';
  END IF;

  SELECT employee.*
  INTO v_employee
  FROM public.store_employees employee
  WHERE employee.id = p_employee_id
    AND employee.store_id = p_store_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND';
  END IF;

  RETURN QUERY
  SELECT
    log.id,
    log.restaurant_id,
    log.user_id,
    log.employee_id,
    log.type,
    log.photo_url,
    log.photo_thumbnail_url,
    log.logged_at,
    log.created_at,
    v_employee.full_name,
    v_employee.employment_role,
    v_employee.employee_number
  FROM public.attendance_logs log
  WHERE log.restaurant_id = p_store_id
    AND log.employee_id = p_employee_id
    AND log.logged_at >= p_from
    AND log.logged_at < p_to
  ORDER BY log.logged_at DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_employee_attendance_logs(
  uuid,
  uuid,
  timestamptz,
  timestamptz,
  integer
) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_employee_attendance_logs(
  uuid,
  uuid,
  timestamptz,
  timestamptz,
  integer
) TO authenticated;

COMMENT ON FUNCTION public.get_employee_attendance_logs(
  uuid,
  uuid,
  timestamptz,
  timestamptz,
  integer
) IS 'Returns one scoped employee attendance history for manager monthly review.';

COMMIT;
