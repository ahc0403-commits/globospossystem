-- ============================================================
-- QSC mobile role split
-- 2026-05-16
-- Scope:
-- - keep mobile staff input on qc_check
-- - move mobile SV visit review writes to qc_visit_review
-- - keep read access available to both staff input and SV review roles
-- - preserve Office read-model views/contracts owned by the Office app
-- ============================================================

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
  v_can_read BOOLEAN;
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

  v_can_read := v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check']
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_visit_review'];

  IF NOT v_can_read THEN
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

CREATE OR REPLACE FUNCTION public.submit_qc_visit_review(
  p_store_id UUID,
  p_check_ids UUID[],
  p_sv_review_status TEXT,
  p_sv_score NUMERIC DEFAULT NULL,
  p_sv_note TEXT DEFAULT NULL,
  p_visit_session_id UUID DEFAULT NULL,
  p_reviewed_at TIMESTAMPTZ DEFAULT NULL,
  p_reviewed_by UUID DEFAULT NULL
) RETURNS TABLE (
  check_id UUID,
  sv_review_status TEXT,
  sv_reviewed_by UUID,
  sv_reviewed_at TIMESTAMPTZ,
  sv_score NUMERIC,
  visit_session_id UUID
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_review BOOLEAN;
  v_reviewed_by UUID := COALESCE(p_reviewed_by, auth.uid());
  v_note TEXT := NULLIF(btrim(COALESCE(p_sv_note, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_FORBIDDEN';
  END IF;

  v_can_review := v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_visit_review'];

  IF NOT v_can_review THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_FORBIDDEN';
  END IF;

  IF p_check_ids IS NULL OR cardinality(p_check_ids) = 0 THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_CHECKS_REQUIRED';
  END IF;

  IF p_sv_review_status NOT IN ('pending', 'reviewed', 'rejected') THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_STATUS_INVALID';
  END IF;

  IF v_reviewed_by <> auth.uid() THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_ACTOR_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_check_ids) cid
    LEFT JOIN public.qc_checks qc
      ON qc.id = cid
     AND qc.restaurant_id = p_store_id
    WHERE qc.id IS NULL
  ) THEN
    RAISE EXCEPTION 'QC_VISIT_REVIEW_CHECK_NOT_FOUND';
  END IF;

  RETURN QUERY
  UPDATE public.qc_checks qc
  SET
    sv_review_status = p_sv_review_status,
    sv_reviewed_by = CASE
      WHEN p_sv_review_status IN ('reviewed', 'rejected') THEN v_reviewed_by
      ELSE qc.sv_reviewed_by
    END,
    sv_reviewed_at = CASE
      WHEN p_sv_review_status IN ('reviewed', 'rejected') THEN COALESCE(p_reviewed_at, now())
      ELSE p_reviewed_at
    END,
    sv_score = COALESCE(p_sv_score, qc.sv_score),
    sv_note = COALESCE(v_note, qc.sv_note),
    visit_session_id = COALESCE(p_visit_session_id, qc.visit_session_id)
  WHERE qc.restaurant_id = p_store_id
    AND qc.id = ANY(p_check_ids)
  RETURNING
    qc.id,
    qc.sv_review_status,
    qc.sv_reviewed_by,
    qc.sv_reviewed_at,
    qc.sv_score,
    qc.visit_session_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_visit_review_submitted',
    'qc_checks',
    COALESCE(p_check_ids[1], gen_random_uuid()),
    jsonb_build_object(
      'store_id', p_store_id,
      'check_ids', p_check_ids,
      'sv_review_status', p_sv_review_status,
      'sv_score', p_sv_score,
      'sv_note', v_note,
      'visit_session_id', p_visit_session_id
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
