BEGIN;

-- Display RPCs remain compatible with deployed clients. The JSON envelope
-- keeps PostgREST's outer row cap from silently truncating an individual page.
CREATE OR REPLACE FUNCTION public.get_payroll_attendance_page(
  p_store_id uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_page_size integer DEFAULT 500,
  p_after_logged_at timestamptz DEFAULT NULL,
  p_after_id uuid DEFAULT NULL,
  p_expected_revision text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_rows jsonb;
  v_has_more boolean;
  v_revision text;
  v_total_count bigint;
BEGIN
  SELECT actor.* INTO v_actor
  FROM public.users actor
  WHERE actor.auth_id = auth.uid() AND actor.is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role IS NULL OR v_actor.role NOT IN (
    'admin', 'store_admin', 'brand_admin', 'super_admin',
    'photo_objet_master', 'photo_objet_store_admin',
    'photo_objet_store_operator'
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_VIEW_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL OR p_from IS NULL OR p_to IS NULL
     OR p_to <= p_from OR NOT isfinite(p_from) OR NOT isfinite(p_to)
     OR p_page_size IS NULL OR p_page_size NOT BETWEEN 1 AND 500
     OR (p_after_logged_at IS NULL) <> (p_after_id IS NULL)
     OR (p_after_id IS NULL) <> (p_expected_revision IS NULL)
     OR (p_after_logged_at IS NOT NULL AND
         (p_after_logged_at < p_from OR p_after_logged_at >= p_to))
     OR (p_expected_revision IS NOT NULL AND
         p_expected_revision !~ '^[0-9a-f]{32}$') THEN
    RAISE EXCEPTION 'ATTENDANCE_QUERY_INVALID';
  END IF;

  IF v_actor.role <> 'super_admin' AND NOT EXISTS (
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_VIEW_FORBIDDEN';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY page.logged_at, page.id), '[]')
  INTO v_rows
  FROM (
    SELECT log.id, log.restaurant_id, log.user_id, log.employee_id,
      log.type, log.logged_at,
      COALESCE(NULLIF(btrim(employee.full_name), ''),
               NULLIF(btrim(legacy_user.full_name), ''),
               NULLIF(btrim(employee.employee_number), ''), '-') AS person_name,
      COALESCE(NULLIF(btrim(employee.employment_role), ''),
               NULLIF(btrim(legacy_user.role), ''), 'staff') AS person_role,
      employee.employee_number
    FROM public.attendance_logs log
    LEFT JOIN public.store_employees employee ON employee.id = log.employee_id
    LEFT JOIN public.users legacy_user ON legacy_user.id = log.user_id
    WHERE log.restaurant_id = p_store_id
      AND log.logged_at >= p_from AND log.logged_at < p_to
      AND (p_after_id IS NULL OR
           (log.logged_at, log.id) > (p_after_logged_at, p_after_id))
    ORDER BY log.logged_at, log.id
    LIMIT p_page_size + 1
  ) page;

  v_has_more := jsonb_array_length(v_rows) > p_page_size;
  IF v_has_more THEN v_rows := v_rows - p_page_size; END IF;

  -- Compare the complete input only on the first and final pages: two scans,
  -- not one per page. xmin also detects edits that restore an earlier value.
  -- This is an optimistic read check, not a persistent exported MVCC snapshot.
  -- A change fails the entire calculation instead of returning a partial wage.
  IF p_after_id IS NULL OR NOT v_has_more THEN
    SELECT md5(p_store_id::text || ':' || extract(epoch FROM p_from)::text ||
               ':' || extract(epoch FROM p_to)::text || ':' ||
               COALESCE(string_agg(
                 format('%s:%s:%s:%s', log.id, log.xmin::text,
                        employee.xmin::text, legacy_user.xmin::text),
                 ',' ORDER BY log.id), '')), count(*)
    INTO v_revision, v_total_count
    FROM public.attendance_logs log
    LEFT JOIN public.store_employees employee ON employee.id = log.employee_id
    LEFT JOIN public.users legacy_user ON legacy_user.id = log.user_id
    WHERE log.restaurant_id = p_store_id
      AND log.logged_at >= p_from AND log.logged_at < p_to;

    IF p_expected_revision IS NOT NULL AND v_revision <> p_expected_revision THEN
      RAISE EXCEPTION 'PAYROLL_ATTENDANCE_CHANGED';
    END IF;
  ELSE
    v_revision := p_expected_revision;
  END IF;

  RETURN jsonb_build_object('rows', v_rows, 'has_more', v_has_more,
                            'revision', v_revision, 'total_count', v_total_count);
END;
$$;

REVOKE ALL ON FUNCTION public.get_payroll_attendance_page(
  uuid, timestamptz, timestamptz, integer, timestamptz, uuid, text
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_payroll_attendance_page(
  uuid, timestamptz, timestamptz, integer, timestamptz, uuid, text
) TO authenticated;

COMMENT ON FUNCTION public.get_payroll_attendance_page(
  uuid, timestamptz, timestamptz, integer, timestamptz, uuid, text
) IS 'Complete payroll attendance through bounded keyset pages; final-page input revision validation rejects concurrent changes. Display RPCs are unchanged.';

COMMIT;
