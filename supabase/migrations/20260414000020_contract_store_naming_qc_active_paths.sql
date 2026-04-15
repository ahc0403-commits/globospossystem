-- ============================================================
-- Contract phase: rename active QC RPC inputs to store naming
-- 2026-04-14
-- Scope:
-- - templates / checks
-- - followups / analytics
-- Notes:
-- - global template reads/writes keep nullable p_store_id
-- - physical schema and storage policies still use restaurant_id during coexistence
-- ============================================================

DROP FUNCTION IF EXISTS public.get_qc_templates(uuid, text);
DROP FUNCTION IF EXISTS public.create_qc_template(text, text, uuid, text, int, boolean);
DROP FUNCTION IF EXISTS public.get_qc_checks(uuid, date, date);
DROP FUNCTION IF EXISTS public.upsert_qc_check(uuid, uuid, date, text, text, text, uuid);
DROP FUNCTION IF EXISTS public.create_qc_followup(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.update_qc_followup_status(uuid, uuid, text, text);
DROP FUNCTION IF EXISTS public.get_qc_followups(uuid, text);
DROP FUNCTION IF EXISTS public.get_qc_analytics(uuid, date, date);

CREATE OR REPLACE FUNCTION public.get_qc_templates(
  p_store_id UUID DEFAULT NULL,
  p_scope TEXT DEFAULT 'visible'
) RETURNS TABLE (
  id UUID,
  restaurant_id UUID,
  category TEXT,
  criteria_text TEXT,
  criteria_photo_url TEXT,
  sort_order INT,
  is_global BOOLEAN,
  is_active BOOLEAN,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
  END IF;

  IF p_scope NOT IN ('visible', 'global') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_SCOPE_INVALID';
  END IF;

  IF p_scope = 'global' THEN
    IF v_actor.role <> 'super_admin' THEN
      RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
    END IF;
  ELSE
    IF p_store_id IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_RESTAURANT_REQUIRED';
    END IF;

    IF v_actor.role <> 'super_admin'
       AND v_actor.restaurant_id <> p_store_id THEN
      RAISE EXCEPTION 'QC_TEMPLATE_READ_FORBIDDEN';
    END IF;
  END IF;

  RETURN QUERY
  SELECT
    qt.id,
    qt.restaurant_id,
    qt.category,
    qt.criteria_text,
    qt.criteria_photo_url,
    qt.sort_order,
    qt.is_global,
    qt.is_active,
    qt.created_at,
    qt.updated_at
  FROM public.qc_templates qt
  WHERE qt.is_active = TRUE
    AND (
      (p_scope = 'global' AND qt.is_global = TRUE)
      OR
      (
        p_scope = 'visible'
        AND (
          qt.is_global = TRUE
          OR qt.restaurant_id = p_store_id
        )
      )
    )
  ORDER BY qt.is_global DESC, lower(qt.category), qt.sort_order, qt.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.create_qc_template(
  p_category TEXT,
  p_criteria_text TEXT,
  p_store_id UUID DEFAULT NULL,
  p_criteria_photo_url TEXT DEFAULT NULL,
  p_sort_order INT DEFAULT 0,
  p_is_global BOOLEAN DEFAULT FALSE
) RETURNS public.qc_templates AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.qc_templates%ROWTYPE;
  v_category TEXT := NULLIF(btrim(COALESCE(p_category, '')), '');
  v_criteria TEXT := NULLIF(btrim(COALESCE(p_criteria_text, '')), '');
  v_photo TEXT := NULLIF(btrim(COALESCE(p_criteria_photo_url, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF v_category IS NULL THEN
    RAISE EXCEPTION 'QC_TEMPLATE_CATEGORY_REQUIRED';
  END IF;

  IF v_criteria IS NULL THEN
    RAISE EXCEPTION 'QC_TEMPLATE_TEXT_REQUIRED';
  END IF;

  IF p_sort_order IS NULL OR p_sort_order < 0 THEN
    RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID';
  END IF;

  IF p_is_global THEN
    IF v_actor.role <> 'super_admin' THEN
      RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
    END IF;
  ELSE
    IF p_store_id IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_RESTAURANT_REQUIRED';
    END IF;

    IF v_actor.role <> 'super_admin'
       AND v_actor.restaurant_id <> p_store_id THEN
      RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
    END IF;
  END IF;

  INSERT INTO public.qc_templates (
    restaurant_id,
    category,
    criteria_text,
    criteria_photo_url,
    sort_order,
    is_global,
    updated_at
  )
  VALUES (
    CASE WHEN p_is_global THEN NULL ELSE p_store_id END,
    v_category,
    v_criteria,
    v_photo,
    p_sort_order,
    p_is_global,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_template_created',
    'qc_templates',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.restaurant_id,
      'is_global', v_created.is_global,
      'category', v_created.category,
      'criteria_text', v_created.criteria_text,
      'criteria_photo_url', v_created.criteria_photo_url,
      'sort_order', v_created.sort_order
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_qc_checks(
  p_store_id UUID,
  p_from DATE,
  p_to DATE
) RETURNS TABLE (
  check_id UUID,
  restaurant_id UUID,
  template_id UUID,
  check_date DATE,
  checked_by UUID,
  result TEXT,
  evidence_photo_url TEXT,
  note TEXT,
  created_at TIMESTAMPTZ,
  template_category TEXT,
  template_criteria_text TEXT,
  template_criteria_photo_url TEXT,
  template_is_global BOOLEAN
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_check BOOLEAN;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN';
  END IF;

  v_can_check := v_actor.role IN ('admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'QC_CHECK_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'QC_CHECK_RANGE_INVALID';
  END IF;

  RETURN QUERY
  SELECT
    qc.id AS check_id,
    qc.restaurant_id,
    qc.template_id,
    qc.check_date,
    qc.checked_by,
    qc.result,
    qc.evidence_photo_url,
    qc.note,
    qc.created_at,
    qt.category AS template_category,
    qt.criteria_text AS template_criteria_text,
    qt.criteria_photo_url AS template_criteria_photo_url,
    qt.is_global AS template_is_global
  FROM public.qc_checks qc
  JOIN public.qc_templates qt
    ON qt.id = qc.template_id
  WHERE qc.restaurant_id = p_store_id
    AND qc.check_date >= p_from
    AND qc.check_date <= p_to
  ORDER BY qc.check_date DESC, lower(qt.category), qt.sort_order, qc.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.upsert_qc_check(
  p_store_id UUID,
  p_template_id UUID,
  p_check_date DATE,
  p_result TEXT,
  p_evidence_photo_url TEXT DEFAULT NULL,
  p_note TEXT DEFAULT NULL,
  p_checked_by UUID DEFAULT NULL
) RETURNS public.qc_checks AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_check BOOLEAN;
  v_template public.qc_templates%ROWTYPE;
  v_existing public.qc_checks%ROWTYPE;
  v_saved public.qc_checks%ROWTYPE;
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_photo TEXT := NULLIF(btrim(COALESCE(p_evidence_photo_url, '')), '');
  v_checked_by UUID := COALESCE(p_checked_by, auth.uid());
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN';
  END IF;

  v_can_check := v_actor.role IN ('admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN';
  END IF;

  IF p_template_id IS NULL THEN
    RAISE EXCEPTION 'QC_CHECK_TEMPLATE_REQUIRED';
  END IF;

  IF p_check_date IS NULL THEN
    RAISE EXCEPTION 'QC_CHECK_DATE_REQUIRED';
  END IF;

  IF p_result NOT IN ('pass', 'fail', 'na') THEN
    RAISE EXCEPTION 'QC_CHECK_RESULT_INVALID';
  END IF;

  IF v_checked_by <> auth.uid() THEN
    RAISE EXCEPTION 'QC_CHECK_ACTOR_INVALID';
  END IF;

  SELECT qt.*
  INTO v_template
  FROM public.qc_templates qt
  WHERE qt.id = p_template_id
    AND qt.is_active = TRUE
    AND (
      qt.is_global = TRUE
      OR qt.restaurant_id = p_store_id
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_TEMPLATE_NOT_FOUND';
  END IF;

  SELECT qc.*
  INTO v_existing
  FROM public.qc_checks qc
  WHERE qc.template_id = p_template_id
    AND qc.check_date = p_check_date
  FOR UPDATE;

  INSERT INTO public.qc_checks (
    restaurant_id,
    template_id,
    check_date,
    checked_by,
    result,
    evidence_photo_url,
    note
  )
  VALUES (
    p_store_id,
    p_template_id,
    p_check_date,
    v_checked_by,
    p_result,
    v_photo,
    v_note
  )
  ON CONFLICT (template_id, check_date)
  DO UPDATE SET
    restaurant_id = EXCLUDED.restaurant_id,
    checked_by = EXCLUDED.checked_by,
    result = EXCLUDED.result,
    evidence_photo_url = EXCLUDED.evidence_photo_url,
    note = EXCLUDED.note
  RETURNING * INTO v_saved;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_check_upserted',
    'qc_checks',
    v_saved.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'template_id', p_template_id,
      'check_date', p_check_date,
      'result', p_result,
      'evidence_photo_url', v_photo,
      'note', v_note,
      'previous_check', CASE
        WHEN v_existing.id IS NULL THEN NULL
        ELSE jsonb_build_object(
          'result', v_existing.result,
          'evidence_photo_url', v_existing.evidence_photo_url,
          'note', v_existing.note,
          'checked_by', v_existing.checked_by
        )
      END
    )
  );

  RETURN v_saved;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.create_qc_followup(
  p_store_id UUID,
  p_source_check_id UUID,
  p_assigned_to_name TEXT DEFAULT NULL
) RETURNS public.qc_followups AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_check public.qc_checks%ROWTYPE;
  v_created public.qc_followups%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  SELECT * INTO v_check
  FROM public.qc_checks
  WHERE id = p_source_check_id
    AND restaurant_id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_CHECK_NOT_FOUND';
  END IF;

  IF v_check.result <> 'fail' THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_NOT_FAILED_CHECK';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.qc_followups
    WHERE source_check_id = p_source_check_id
  ) THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_ALREADY_EXISTS';
  END IF;

  INSERT INTO public.qc_followups (
    restaurant_id, source_check_id, status,
    assigned_to_name, created_by
  ) VALUES (
    p_store_id, p_source_check_id, 'open',
    NULLIF(btrim(COALESCE(p_assigned_to_name, '')), ''),
    auth.uid()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_followup_created',
    'qc_followups',
    v_created.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'source_check_id', p_source_check_id,
      'assigned_to_name', v_created.assigned_to_name
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.update_qc_followup_status(
  p_followup_id UUID,
  p_store_id UUID,
  p_status TEXT,
  p_resolution_notes TEXT DEFAULT NULL
) RETURNS public.qc_followups AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.qc_followups%ROWTYPE;
  v_updated public.qc_followups%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF p_status NOT IN ('open', 'in_progress', 'resolved') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_STATUS_INVALID';
  END IF;

  SELECT * INTO v_existing
  FROM public.qc_followups
  WHERE id = p_followup_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_NOT_FOUND';
  END IF;

  UPDATE public.qc_followups
  SET status = p_status,
      resolution_notes = CASE
        WHEN p_resolution_notes IS NOT NULL
        THEN NULLIF(btrim(p_resolution_notes), '')
        ELSE resolution_notes
      END,
      updated_at = now(),
      resolved_at = CASE
        WHEN p_status = 'resolved' THEN now()
        ELSE NULL
      END
  WHERE id = p_followup_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_followup_status_updated',
    'qc_followups',
    v_updated.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'old_status', v_existing.status,
      'new_status', p_status,
      'resolution_notes', v_updated.resolution_notes
    )
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_qc_followups(
  p_store_id UUID,
  p_status_filter TEXT DEFAULT NULL
) RETURNS TABLE (
  followup_id UUID,
  restaurant_id UUID,
  source_check_id UUID,
  status TEXT,
  assigned_to_name TEXT,
  resolution_notes TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  resolved_at TIMESTAMPTZ,
  check_date DATE,
  check_result TEXT,
  check_note TEXT,
  template_category TEXT,
  template_criteria TEXT
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_READ_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_READ_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    f.id AS followup_id,
    f.restaurant_id,
    f.source_check_id,
    f.status,
    f.assigned_to_name,
    f.resolution_notes,
    f.created_at,
    f.updated_at,
    f.resolved_at,
    qc.check_date,
    qc.result AS check_result,
    qc.note AS check_note,
    qt.category AS template_category,
    qt.criteria_text AS template_criteria
  FROM public.qc_followups f
  JOIN public.qc_checks qc ON qc.id = f.source_check_id
  JOIN public.qc_templates qt ON qt.id = qc.template_id
  WHERE f.restaurant_id = p_store_id
    AND (p_status_filter IS NULL OR f.status = p_status_filter)
  ORDER BY
    CASE f.status
      WHEN 'open' THEN 0
      WHEN 'in_progress' THEN 1
      WHEN 'resolved' THEN 2
    END,
    f.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_qc_analytics(
  p_store_id UUID,
  p_from DATE,
  p_to DATE
) RETURNS TABLE (
  total_checks BIGINT,
  pass_count BIGINT,
  fail_count BIGINT,
  na_count BIGINT,
  pass_rate NUMERIC,
  template_count BIGINT,
  coverage NUMERIC,
  open_followups BIGINT
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_check BOOLEAN;
  v_days INT;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN';
  END IF;

  v_can_check := v_actor.role IN ('admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'QC_ANALYTICS_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'QC_ANALYTICS_RANGE_INVALID';
  END IF;

  v_days := (p_to - p_from) + 1;

  RETURN QUERY
  SELECT
    COUNT(*)::BIGINT AS total_checks,
    COUNT(*) FILTER (WHERE qc.result = 'pass')::BIGINT AS pass_count,
    COUNT(*) FILTER (WHERE qc.result = 'fail')::BIGINT AS fail_count,
    COUNT(*) FILTER (WHERE qc.result = 'na')::BIGINT AS na_count,
    CASE
      WHEN COUNT(*) FILTER (WHERE qc.result IN ('pass','fail')) = 0 THEN 0::NUMERIC
      ELSE ROUND(
        COUNT(*) FILTER (WHERE qc.result = 'pass')::NUMERIC
        / COUNT(*) FILTER (WHERE qc.result IN ('pass','fail'))::NUMERIC * 100,
        1
      )
    END AS pass_rate,
    (SELECT COUNT(*) FROM public.qc_templates qt
     WHERE qt.is_active = TRUE
       AND (qt.is_global = TRUE OR qt.restaurant_id = p_store_id)
    )::BIGINT AS template_count,
    CASE
      WHEN (SELECT COUNT(*) FROM public.qc_templates qt
            WHERE qt.is_active = TRUE
              AND (qt.is_global = TRUE OR qt.restaurant_id = p_store_id)) = 0
      THEN 0::NUMERIC
      ELSE ROUND(
        COUNT(*)::NUMERIC
        / ((SELECT COUNT(*) FROM public.qc_templates qt
            WHERE qt.is_active = TRUE
              AND (qt.is_global = TRUE OR qt.restaurant_id = p_store_id))
           * v_days)::NUMERIC * 100,
        1
      )
    END AS coverage,
    (SELECT COUNT(*) FROM public.qc_followups f
     WHERE f.restaurant_id = p_store_id
       AND f.status IN ('open', 'in_progress')
    )::BIGINT AS open_followups
  FROM public.qc_checks qc
  WHERE qc.restaurant_id = p_store_id
    AND qc.check_date >= p_from
    AND qc.check_date <= p_to;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
