BEGIN;
CREATE OR REPLACE FUNCTION public.get_payroll_hourly_rules(
  p_store_id uuid, p_employee_ids uuid[]
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = public, auth, pg_catalog AS $$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR p_store_id IS NULL
    OR NOT COALESCE(public.workforce_can_manage_store(p_store_id), false) THEN
    RAISE EXCEPTION 'PAYROLL_RULES_FORBIDDEN';
  END IF;
  IF COALESCE(cardinality(p_employee_ids), 0) NOT BETWEEN 1 AND 500
    OR array_ndims(p_employee_ids) <> 1
    OR EXISTS (SELECT 1 FROM unnest(p_employee_ids) e(id) WHERE e.id IS NULL)
    OR (SELECT count(DISTINCT e.id) FROM unnest(p_employee_ids) e(id)) <> cardinality(p_employee_ids) THEN
    RAISE EXCEPTION 'PAYROLL_RULES_QUERY_INVALID';
  END IF;
  SELECT jsonb_build_object('version', 1, 'store_id', p_store_id,
    'rows', jsonb_agg(jsonb_build_object('employee_id', e.id, 'rule',
      CASE WHEN r.employee_id IS NULL THEN NULL ELSE jsonb_build_object(
        'hourly_rate', r.hourly_rate, 'scheduled_start', r.scheduled_start,
        'night_start', r.night_start, 'night_multiplier', r.night_multiplier,
        'holiday_multiplier', r.holiday_multiplier, 'exclude_sunday', r.exclude_sunday,
        'late_threshold_minutes', r.late_threshold_minutes,
        'late_review_hourly_multiplier', r.late_review_hourly_multiplier
      ) END) ORDER BY e.id)) INTO v_result
  FROM unnest(p_employee_ids) e(id)
  LEFT JOIN public.employee_hourly_pay_rules r
    ON r.employee_id = e.id AND r.store_id = p_store_id;
  RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.get_payroll_hourly_rules(uuid, uuid[])
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_payroll_hourly_rules(uuid, uuid[]) TO authenticated;
COMMIT;
