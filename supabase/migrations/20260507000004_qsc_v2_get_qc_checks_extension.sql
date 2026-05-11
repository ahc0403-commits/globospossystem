-- ============================================================
-- QSC v2 Wave 4b: get_qc_checks read contract extension
-- 2026-05-07
-- Scope:
-- - extend get_qc_checks return payload with QSC v2 fields
-- - preserve the legacy columns and ordering at the front
-- Notes:
-- - callers using only legacy keys remain compatible
-- - new columns are appended after the existing template fields
-- ============================================================

DROP FUNCTION IF EXISTS public.get_qc_checks(UUID, DATE, DATE);

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
  template_is_global BOOLEAN,
  submitted_at TIMESTAMPTZ,
  submission_status TEXT,
  photo_required_count INTEGER,
  photo_uploaded_count INTEGER,
  score NUMERIC,
  grade TEXT,
  sv_review_status TEXT,
  sv_reviewed_by UUID,
  sv_reviewed_at TIMESTAMPTZ,
  sv_score NUMERIC,
  sv_note TEXT,
  visit_session_id UUID,
  template_qsc_domain TEXT,
  template_requires_photo BOOLEAN,
  template_required_photo_count INTEGER,
  template_weight NUMERIC,
  template_sort_group TEXT,
  template_is_sv_required BOOLEAN
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

  v_can_check := v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_CHECK_READ_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
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
    qt.is_global AS template_is_global,
    qc.submitted_at,
    qc.submission_status,
    qc.photo_required_count,
    qc.photo_uploaded_count,
    qc.score,
    qc.grade,
    qc.sv_review_status,
    qc.sv_reviewed_by,
    qc.sv_reviewed_at,
    qc.sv_score,
    qc.sv_note,
    qc.visit_session_id,
    qt.qsc_domain AS template_qsc_domain,
    qt.requires_photo AS template_requires_photo,
    qt.required_photo_count AS template_required_photo_count,
    qt.weight AS template_weight,
    qt.sort_group AS template_sort_group,
    qt.is_sv_required AS template_is_sv_required
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
