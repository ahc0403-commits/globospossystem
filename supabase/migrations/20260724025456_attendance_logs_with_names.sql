BEGIN;

CREATE INDEX IF NOT EXISTS attendance_logs_store_logged_at_idx
  ON public.attendance_logs(restaurant_id, logged_at DESC);

CREATE OR REPLACE FUNCTION public.get_attendance_logs_with_names(
  p_store_id uuid,
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
    COALESCE(
      NULLIF(btrim(employee.full_name), ''),
      NULLIF(btrim(legacy_user.full_name), ''),
      NULLIF(btrim(employee.employee_number), ''),
      '-'
    ) AS person_name,
    COALESCE(
      NULLIF(btrim(employee.employment_role), ''),
      NULLIF(btrim(legacy_user.role), ''),
      'staff'
    ) AS person_role,
    employee.employee_number
  FROM public.attendance_logs log
  LEFT JOIN public.store_employees employee
    ON employee.id = log.employee_id
  LEFT JOIN public.users legacy_user
    ON legacy_user.id = log.user_id
  WHERE log.restaurant_id = p_store_id
    AND log.logged_at >= p_from
    AND log.logged_at < p_to
  ORDER BY log.logged_at DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_attendance_logs_with_names(
  uuid,
  timestamptz,
  timestamptz,
  integer
) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_attendance_logs_with_names(
  uuid,
  timestamptz,
  timestamptz,
  integer
) TO authenticated;

COMMENT ON FUNCTION public.get_attendance_logs_with_names(
  uuid,
  timestamptz,
  timestamptz,
  integer
) IS
  'Returns scoped attendance display rows with employee names without exposing full employee profiles.';

COMMIT;
