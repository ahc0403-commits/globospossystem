-- ============================================================
-- POS QC contract closure
-- 2026-04-09
-- Bounded scope:
-- - visible QC template read
-- - QC template create/update/deactivate
-- - QC check read/upsert
-- - super-admin global template read
-- - super-admin QC overview read
-- - server-owned validation and audit traces
-- Out of scope:
-- - broader analytics/governance redesign
-- - storage model redesign for qc-photos
-- ============================================================

ALTER TABLE public.qc_templates
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE OR REPLACE FUNCTION public.get_qc_templates(
  p_restaurant_id UUID DEFAULT NULL,
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
    IF p_restaurant_id IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_RESTAURANT_REQUIRED';
    END IF;

    IF v_actor.role <> 'super_admin'
       AND v_actor.restaurant_id <> p_restaurant_id THEN
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
          OR qt.restaurant_id = p_restaurant_id
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
  p_restaurant_id UUID DEFAULT NULL,
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
    IF p_restaurant_id IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_RESTAURANT_REQUIRED';
    END IF;

    IF v_actor.role <> 'super_admin'
       AND v_actor.restaurant_id <> p_restaurant_id THEN
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
    CASE WHEN p_is_global THEN NULL ELSE p_restaurant_id END,
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
      'restaurant_id', v_created.restaurant_id,
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

CREATE OR REPLACE FUNCTION public.update_qc_template(
  p_template_id UUID,
  p_patch JSONB
) RETURNS public.qc_templates AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.qc_templates%ROWTYPE;
  v_updated public.qc_templates%ROWTYPE;
  v_patch JSONB := COALESCE(p_patch, '{}'::JSONB);
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_key TEXT;
  v_value JSONB;
  v_category TEXT;
  v_text TEXT;
  v_photo TEXT;
  v_sort_order INT;
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

  IF jsonb_typeof(v_patch) <> 'object' THEN
    RAISE EXCEPTION 'QC_TEMPLATE_PATCH_INVALID';
  END IF;

  IF v_patch = '{}'::JSONB THEN
    RAISE EXCEPTION 'QC_TEMPLATE_PATCH_EMPTY';
  END IF;

  SELECT qt.*
  INTO v_existing
  FROM public.qc_templates qt
  WHERE qt.id = p_template_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_TEMPLATE_NOT_FOUND';
  END IF;

  IF v_existing.is_global AND v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF NOT v_existing.is_global
     AND v_actor.role <> 'super_admin'
     AND v_existing.restaurant_id <> v_actor.restaurant_id THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  FOR v_key, v_value IN
    SELECT key, value FROM jsonb_each(v_patch)
  LOOP
    IF v_key NOT IN ('category', 'criteria_text', 'criteria_photo_url', 'sort_order') THEN
      RAISE EXCEPTION 'QC_TEMPLATE_PATCH_UNSUPPORTED';
    END IF;
  END LOOP;

  v_category := v_existing.category;
  v_text := v_existing.criteria_text;
  v_photo := v_existing.criteria_photo_url;
  v_sort_order := v_existing.sort_order;

  IF v_patch ? 'category' THEN
    v_category := NULLIF(btrim(v_patch->>'category'), '');
    IF v_category IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_CATEGORY_REQUIRED';
    END IF;
    IF v_category IS DISTINCT FROM v_existing.category THEN
      v_changed_fields := array_append(v_changed_fields, 'category');
      v_old_values := v_old_values || jsonb_build_object('category', v_existing.category);
      v_new_values := v_new_values || jsonb_build_object('category', v_category);
    END IF;
  END IF;

  IF v_patch ? 'criteria_text' THEN
    v_text := NULLIF(btrim(v_patch->>'criteria_text'), '');
    IF v_text IS NULL THEN
      RAISE EXCEPTION 'QC_TEMPLATE_TEXT_REQUIRED';
    END IF;
    IF v_text IS DISTINCT FROM v_existing.criteria_text THEN
      v_changed_fields := array_append(v_changed_fields, 'criteria_text');
      v_old_values := v_old_values || jsonb_build_object('criteria_text', v_existing.criteria_text);
      v_new_values := v_new_values || jsonb_build_object('criteria_text', v_text);
    END IF;
  END IF;

  IF v_patch ? 'criteria_photo_url' THEN
    v_photo := NULLIF(btrim(COALESCE(v_patch->>'criteria_photo_url', '')), '');
    IF v_photo IS DISTINCT FROM v_existing.criteria_photo_url THEN
      v_changed_fields := array_append(v_changed_fields, 'criteria_photo_url');
      v_old_values := v_old_values || jsonb_build_object('criteria_photo_url', v_existing.criteria_photo_url);
      v_new_values := v_new_values || jsonb_build_object('criteria_photo_url', v_photo);
    END IF;
  END IF;

  IF v_patch ? 'sort_order' THEN
    BEGIN
      v_sort_order := (v_patch->>'sort_order')::INT;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID';
    END;
    IF v_sort_order < 0 THEN
      RAISE EXCEPTION 'QC_TEMPLATE_SORT_INVALID';
    END IF;
    IF v_sort_order IS DISTINCT FROM v_existing.sort_order THEN
      v_changed_fields := array_append(v_changed_fields, 'sort_order');
      v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
      v_new_values := v_new_values || jsonb_build_object('sort_order', v_sort_order);
    END IF;
  END IF;

  UPDATE public.qc_templates
  SET category = v_category,
      criteria_text = v_text,
      criteria_photo_url = v_photo,
      sort_order = v_sort_order,
      updated_at = now()
  WHERE id = p_template_id
  RETURNING * INTO v_updated;

  IF array_length(v_changed_fields, 1) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'qc_template_updated',
      'qc_templates',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'is_global', v_updated.is_global,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.deactivate_qc_template(
  p_template_id UUID
) RETURNS public.qc_templates AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.qc_templates%ROWTYPE;
  v_updated public.qc_templates%ROWTYPE;
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

  SELECT qt.*
  INTO v_existing
  FROM public.qc_templates qt
  WHERE qt.id = p_template_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_TEMPLATE_NOT_FOUND';
  END IF;

  IF v_existing.is_global AND v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  IF NOT v_existing.is_global
     AND v_actor.role <> 'super_admin'
     AND v_existing.restaurant_id <> v_actor.restaurant_id THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  UPDATE public.qc_templates
  SET is_active = FALSE,
      updated_at = now()
  WHERE id = p_template_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_template_deactivated',
    'qc_templates',
    v_updated.id,
    jsonb_build_object(
      'restaurant_id', v_updated.restaurant_id,
      'is_global', v_updated.is_global
    )
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_qc_checks(
  p_restaurant_id UUID,
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
     AND v_actor.restaurant_id <> p_restaurant_id THEN
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
  WHERE qc.restaurant_id = p_restaurant_id
    AND qc.check_date >= p_from
    AND qc.check_date <= p_to
  ORDER BY qc.check_date DESC, lower(qt.category), qt.sort_order, qc.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.upsert_qc_check(
  p_restaurant_id UUID,
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
     AND v_actor.restaurant_id <> p_restaurant_id THEN
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
      OR qt.restaurant_id = p_restaurant_id
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
    p_restaurant_id,
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
      'restaurant_id', p_restaurant_id,
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

CREATE OR REPLACE FUNCTION public.get_qc_superadmin_summary(
  p_week_start DATE
) RETURNS TABLE (
  restaurant_id UUID,
  restaurant_name TEXT,
  coverage NUMERIC,
  fail_count BIGINT,
  latest_check_date DATE
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_week_end DATE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'QC_SUMMARY_FORBIDDEN';
  END IF;

  IF p_week_start IS NULL THEN
    RAISE EXCEPTION 'QC_SUMMARY_WEEK_REQUIRED';
  END IF;

  v_week_end := p_week_start + 6;

  RETURN QUERY
  WITH active_restaurants AS (
    SELECT r.id, r.name
    FROM public.restaurants r
    WHERE r.is_active = TRUE
  ),
  template_counts AS (
    SELECT
      ar.id AS restaurant_id,
      COUNT(*) FILTER (
        WHERE qt.is_active = TRUE
          AND (qt.is_global = TRUE OR qt.restaurant_id = ar.id)
      )::INT AS template_count
    FROM active_restaurants ar
    LEFT JOIN public.qc_templates qt
      ON qt.is_active = TRUE
     AND (qt.is_global = TRUE OR qt.restaurant_id = ar.id)
    GROUP BY ar.id
  ),
  checks AS (
    SELECT
      qc.restaurant_id,
      COUNT(*)::BIGINT AS checked_count,
      COUNT(*) FILTER (WHERE qc.result = 'fail')::BIGINT AS fail_count,
      MAX(qc.check_date) AS latest_check_date
    FROM public.qc_checks qc
    WHERE qc.check_date >= p_week_start
      AND qc.check_date <= v_week_end
    GROUP BY qc.restaurant_id
  )
  SELECT
    ar.id AS restaurant_id,
    ar.name AS restaurant_name,
    CASE
      WHEN COALESCE(tc.template_count, 0) = 0 THEN 0::NUMERIC
      ELSE ROUND(
        COALESCE(ch.checked_count, 0)::NUMERIC
        / (tc.template_count * 7)::NUMERIC * 100,
        2
      )
    END AS coverage,
    COALESCE(ch.fail_count, 0) AS fail_count,
    ch.latest_check_date
  FROM active_restaurants ar
  LEFT JOIN template_counts tc
    ON tc.restaurant_id = ar.id
  LEFT JOIN checks ch
    ON ch.restaurant_id = ar.id
  ORDER BY lower(ar.name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
