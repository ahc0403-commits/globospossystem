DO $$ BEGIN
  IF to_regprocedure('public.workforce_can_manage_store(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PAYROLL_RULES_SCOPE_HELPER_MISSING';
  END IF;
  PERFORM r.employee_id, r.store_id, r.hourly_rate, r.scheduled_start,
    r.night_start, r.night_multiplier, r.holiday_multiplier, r.exclude_sunday,
    r.late_threshold_minutes, r.late_review_hourly_multiplier
  FROM public.employee_hourly_pay_rules r WHERE false;
END $$;
