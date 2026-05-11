-- ============================================================
-- QSC v2 Wave 4: RPC contract extensions
-- 2026-05-07
-- Scope:
-- - extend upsert_qc_check with optional QSC v2 write fields
-- - add photo-write RPC for qc_check_photos
-- - add batch SV review RPC without introducing a new visit table
-- Notes:
-- - old clients remain compatible by omitting the new trailing params
-- - this wave assumes Wave 1 and Wave 2 already exist
-- ============================================================

-- ------------------------------------------------------------
-- Internal helper: sync photo summary back to qc_checks
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.refresh_qc_check_photo_summary(
  p_check_id UUID,
  p_sync_legacy_photo BOOLEAN DEFAULT TRUE
) RETURNS public.qc_checks AS $$
DECLARE
  v_check public.qc_checks%ROWTYPE;
  v_required_count INTEGER;
  v_uploaded_count INTEGER;
  v_primary_photo_url TEXT;
BEGIN
  SELECT qc.*
  INTO v_check
  FROM public.qc_checks qc
  WHERE qc.id = p_check_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_NOT_FOUND';
  END IF;

  SELECT
    CASE
      WHEN COALESCE(qt.requires_photo, TRUE) THEN COALESCE(qt.required_photo_count, 1)
      ELSE 0
    END
  INTO v_required_count
  FROM public.qc_templates qt
  WHERE qt.id = v_check.template_id;

  SELECT COUNT(*)::INTEGER
  INTO v_uploaded_count
  FROM public.qc_check_photos p
  WHERE p.check_id = p_check_id;

  SELECT p.photo_url
  INTO v_primary_photo_url
  FROM public.qc_check_photos p
  WHERE p.check_id = p_check_id
  ORDER BY p.is_primary DESC, p.uploaded_at DESC, p.id DESC
  LIMIT 1;

  UPDATE public.qc_checks qc
  SET
    photo_required_count = COALESCE(qc.photo_required_count, v_required_count),
    photo_uploaded_count = COALESCE(v_uploaded_count, 0),
    evidence_photo_url = CASE
      WHEN p_sync_legacy_photo THEN v_primary_photo_url
      ELSE qc.evidence_photo_url
    END
  WHERE qc.id = p_check_id
  RETURNING * INTO v_check;

  RETURN v_check;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

COMMENT ON FUNCTION public.refresh_qc_check_photo_summary(UUID, BOOLEAN) IS
  'Internal helper that recomputes photo counters and representative photo URL on qc_checks from qc_check_photos.';

-- ------------------------------------------------------------
-- Extended upsert_qc_check
-- Preserve the original function name and the first 7 parameters.
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.upsert_qc_check(UUID, UUID, DATE, TEXT, TEXT, TEXT, UUID);

CREATE OR REPLACE FUNCTION public.upsert_qc_check(
  p_store_id UUID,
  p_template_id UUID,
  p_check_date DATE,
  p_result TEXT,
  p_evidence_photo_url TEXT DEFAULT NULL,
  p_note TEXT DEFAULT NULL,
  p_checked_by UUID DEFAULT NULL,
  p_submitted_at TIMESTAMPTZ DEFAULT NULL,
  p_submission_status TEXT DEFAULT NULL,
  p_photo_required_count INTEGER DEFAULT NULL,
  p_photo_uploaded_count INTEGER DEFAULT NULL,
  p_score NUMERIC DEFAULT NULL,
  p_grade TEXT DEFAULT NULL,
  p_sv_review_status TEXT DEFAULT NULL,
  p_sv_reviewed_by UUID DEFAULT NULL,
  p_sv_reviewed_at TIMESTAMPTZ DEFAULT NULL,
  p_sv_score NUMERIC DEFAULT NULL,
  p_sv_note TEXT DEFAULT NULL,
  p_visit_session_id UUID DEFAULT NULL
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
  v_submission_status TEXT;
  v_submitted_at TIMESTAMPTZ;
  v_photo_required_count INTEGER;
  v_photo_uploaded_count INTEGER;
  v_grade TEXT := NULLIF(btrim(COALESCE(p_grade, '')), '');
  v_sv_review_status TEXT;
  v_sv_reviewed_by UUID;
  v_sv_reviewed_at TIMESTAMPTZ;
  v_sv_note TEXT := NULLIF(btrim(COALESCE(p_sv_note, '')), '');
  v_score NUMERIC;
  v_sv_score NUMERIC;
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

  v_can_check := v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_CHECK_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
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
    AND qc.restaurant_id = p_store_id
    AND qc.check_date = p_check_date
  FOR UPDATE;

  v_submission_status := COALESCE(
    NULLIF(btrim(COALESCE(p_submission_status, '')), ''),
    v_existing.submission_status,
    'submitted'
  );

  IF v_submission_status NOT IN ('pending', 'submitted', 'overdue') THEN
    RAISE EXCEPTION 'QC_CHECK_SUBMISSION_STATUS_INVALID';
  END IF;

  v_submitted_at := CASE
    WHEN v_submission_status = 'submitted' THEN COALESCE(
      p_submitted_at,
      v_existing.submitted_at,
      now()
    )
    ELSE p_submitted_at
  END;

  v_photo_required_count := COALESCE(
    p_photo_required_count,
    v_existing.photo_required_count,
    CASE
      WHEN COALESCE(v_template.requires_photo, TRUE) THEN COALESCE(v_template.required_photo_count, 1)
      ELSE 0
    END
  );

  IF v_photo_required_count < 0 THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_REQUIRED_COUNT_INVALID';
  END IF;

  v_photo_uploaded_count := COALESCE(
    p_photo_uploaded_count,
    v_existing.photo_uploaded_count,
    CASE
      WHEN v_photo IS NOT NULL THEN 1
      ELSE 0
    END
  );

  IF v_photo_uploaded_count < 0 THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_UPLOADED_COUNT_INVALID';
  END IF;

  v_score := COALESCE(p_score, v_existing.score);
  v_sv_score := COALESCE(p_sv_score, v_existing.sv_score);

  IF v_grade IS NOT NULL
     AND v_grade NOT IN ('good', 'caution', 'risk') THEN
    RAISE EXCEPTION 'QC_CHECK_GRADE_INVALID';
  END IF;

  v_grade := COALESCE(v_grade, v_existing.grade);

  v_sv_review_status := COALESCE(
    NULLIF(btrim(COALESCE(p_sv_review_status, '')), ''),
    v_existing.sv_review_status,
    CASE
      WHEN COALESCE(v_template.is_sv_required, FALSE) THEN 'pending'
      ELSE 'not_required'
    END
  );

  IF v_sv_review_status NOT IN ('not_required', 'pending', 'reviewed', 'rejected') THEN
    RAISE EXCEPTION 'QC_CHECK_SV_REVIEW_STATUS_INVALID';
  END IF;

  v_sv_reviewed_by := COALESCE(
    p_sv_reviewed_by,
    v_existing.sv_reviewed_by,
    CASE
      WHEN v_sv_review_status IN ('reviewed', 'rejected') THEN auth.uid()
      ELSE NULL
    END
  );

  IF v_sv_reviewed_by IS NOT NULL
     AND v_sv_reviewed_by <> auth.uid() THEN
    RAISE EXCEPTION 'QC_CHECK_SV_ACTOR_INVALID';
  END IF;

  v_sv_reviewed_at := CASE
    WHEN v_sv_review_status IN ('reviewed', 'rejected') THEN COALESCE(
      p_sv_reviewed_at,
      v_existing.sv_reviewed_at,
      now()
    )
    WHEN p_sv_reviewed_at IS NOT NULL THEN p_sv_reviewed_at
    ELSE v_existing.sv_reviewed_at
  END;

  INSERT INTO public.qc_checks (
    restaurant_id,
    template_id,
    check_date,
    checked_by,
    result,
    evidence_photo_url,
    note,
    submitted_at,
    submission_status,
    photo_required_count,
    photo_uploaded_count,
    score,
    grade,
    sv_review_status,
    sv_reviewed_by,
    sv_reviewed_at,
    sv_score,
    sv_note,
    visit_session_id
  )
  VALUES (
    p_store_id,
    p_template_id,
    p_check_date,
    v_checked_by,
    p_result,
    v_photo,
    v_note,
    v_submitted_at,
    v_submission_status,
    v_photo_required_count,
    v_photo_uploaded_count,
    v_score,
    v_grade,
    v_sv_review_status,
    v_sv_reviewed_by,
    v_sv_reviewed_at,
    v_sv_score,
    v_sv_note,
    COALESCE(p_visit_session_id, v_existing.visit_session_id)
  )
  ON CONFLICT (restaurant_id, template_id, check_date)
  DO UPDATE SET
    restaurant_id = EXCLUDED.restaurant_id,
    checked_by = EXCLUDED.checked_by,
    result = EXCLUDED.result,
    evidence_photo_url = EXCLUDED.evidence_photo_url,
    note = EXCLUDED.note,
    submitted_at = EXCLUDED.submitted_at,
    submission_status = EXCLUDED.submission_status,
    photo_required_count = EXCLUDED.photo_required_count,
    photo_uploaded_count = EXCLUDED.photo_uploaded_count,
    score = EXCLUDED.score,
    grade = EXCLUDED.grade,
    sv_review_status = EXCLUDED.sv_review_status,
    sv_reviewed_by = EXCLUDED.sv_reviewed_by,
    sv_reviewed_at = EXCLUDED.sv_reviewed_at,
    sv_score = EXCLUDED.sv_score,
    sv_note = EXCLUDED.sv_note,
    visit_session_id = EXCLUDED.visit_session_id
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
      'submitted_at', v_submitted_at,
      'submission_status', v_submission_status,
      'photo_required_count', v_photo_required_count,
      'photo_uploaded_count', v_photo_uploaded_count,
      'score', v_score,
      'grade', v_grade,
      'sv_review_status', v_sv_review_status,
      'sv_reviewed_by', v_sv_reviewed_by,
      'sv_reviewed_at', v_sv_reviewed_at,
      'sv_score', v_sv_score,
      'sv_note', v_sv_note,
      'visit_session_id', COALESCE(p_visit_session_id, v_existing.visit_session_id),
      'previous_check', CASE
        WHEN v_existing.id IS NULL THEN NULL
        ELSE jsonb_build_object(
          'result', v_existing.result,
          'evidence_photo_url', v_existing.evidence_photo_url,
          'note', v_existing.note,
          'checked_by', v_existing.checked_by,
          'submitted_at', v_existing.submitted_at,
          'submission_status', v_existing.submission_status,
          'photo_required_count', v_existing.photo_required_count,
          'photo_uploaded_count', v_existing.photo_uploaded_count,
          'score', v_existing.score,
          'grade', v_existing.grade,
          'sv_review_status', v_existing.sv_review_status,
          'sv_reviewed_by', v_existing.sv_reviewed_by,
          'sv_reviewed_at', v_existing.sv_reviewed_at,
          'sv_score', v_existing.sv_score,
          'sv_note', v_existing.sv_note,
          'visit_session_id', v_existing.visit_session_id
        )
      END
    )
  );

  RETURN v_saved;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

COMMENT ON FUNCTION public.upsert_qc_check(
  UUID, UUID, DATE, TEXT, TEXT, TEXT, UUID,
  TIMESTAMPTZ, TEXT, INTEGER, INTEGER, NUMERIC, TEXT,
  TEXT, UUID, TIMESTAMPTZ, NUMERIC, TEXT, UUID
) IS
  'Backward-compatible QSC write anchor. Old callers can keep sending the original 7 params; QSC v2 callers may send the optional trailing fields.';

-- ------------------------------------------------------------
-- Photo write RPC
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_qc_check_photo(
  p_store_id UUID,
  p_check_id UUID,
  p_template_id UUID,
  p_photo_url TEXT,
  p_storage_path TEXT,
  p_photo_role TEXT DEFAULT 'staff',
  p_uploaded_by UUID DEFAULT NULL,
  p_taken_at TIMESTAMPTZ DEFAULT NULL,
  p_is_primary BOOLEAN DEFAULT FALSE,
  p_caption TEXT DEFAULT NULL,
  p_sync_legacy_photo BOOLEAN DEFAULT TRUE
) RETURNS public.qc_check_photos AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_can_check BOOLEAN;
  v_check public.qc_checks%ROWTYPE;
  v_saved public.qc_check_photos%ROWTYPE;
  v_uploaded_by UUID := COALESCE(p_uploaded_by, auth.uid());
  v_caption TEXT := NULLIF(btrim(COALESCE(p_caption, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_WRITE_FORBIDDEN';
  END IF;

  v_can_check := v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

  IF NOT v_can_check THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_WRITE_FORBIDDEN';
  END IF;

  IF v_uploaded_by <> auth.uid() THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_ACTOR_INVALID';
  END IF;

  IF p_photo_role NOT IN ('staff', 'sv', 'reference') THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_ROLE_INVALID';
  END IF;

  SELECT qc.*
  INTO v_check
  FROM public.qc_checks qc
  WHERE qc.id = p_check_id
    AND qc.restaurant_id = p_store_id
    AND qc.template_id = p_template_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QC_CHECK_PHOTO_CHECK_NOT_FOUND';
  END IF;

  IF p_is_primary THEN
    UPDATE public.qc_check_photos
    SET is_primary = FALSE
    WHERE check_id = p_check_id;
  END IF;

  INSERT INTO public.qc_check_photos (
    restaurant_id,
    check_id,
    template_id,
    photo_url,
    storage_path,
    photo_role,
    uploaded_by,
    taken_at,
    is_primary,
    caption
  )
  VALUES (
    p_store_id,
    p_check_id,
    p_template_id,
    NULLIF(btrim(COALESCE(p_photo_url, '')), ''),
    NULLIF(btrim(COALESCE(p_storage_path, '')), ''),
    p_photo_role,
    v_uploaded_by,
    p_taken_at,
    p_is_primary,
    v_caption
  )
  ON CONFLICT (check_id, storage_path)
  DO UPDATE SET
    photo_url = EXCLUDED.photo_url,
    photo_role = EXCLUDED.photo_role,
    uploaded_by = EXCLUDED.uploaded_by,
    uploaded_at = now(),
    taken_at = EXCLUDED.taken_at,
    is_primary = EXCLUDED.is_primary,
    caption = EXCLUDED.caption
  RETURNING * INTO v_saved;

  PERFORM public.refresh_qc_check_photo_summary(p_check_id, p_sync_legacy_photo);

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'qc_check_photo_upserted',
    'qc_check_photos',
    v_saved.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'check_id', p_check_id,
      'template_id', p_template_id,
      'photo_role', p_photo_role,
      'storage_path', p_storage_path,
      'is_primary', p_is_primary
    )
  );

  RETURN v_saved;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ------------------------------------------------------------
-- Batch SV review RPC
-- ------------------------------------------------------------
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
    OR COALESCE(v_actor.extra_permissions, ARRAY[]::TEXT[]) @> ARRAY['qc_check'];

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
