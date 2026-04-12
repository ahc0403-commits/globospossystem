-- ============================================================
-- QC Follow-up + Analytics RPCs
-- 2026-04-10
-- Bounded scope:
--   - qc_followups table (POS-native, restaurant-scoped)
--   - create_qc_followup: create from failed check
--   - update_qc_followup_status: status transition + resolution
--   - get_qc_followups: read followups for restaurant
--   - get_qc_analytics: pass/fail/na stats for date range
-- Out of scope:
--   - office_qc_followups (never applied, office-system design)
--   - notification/alert system
--   - photo/evidence on followups
-- ============================================================

CREATE TABLE IF NOT EXISTS public.qc_followups (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id    UUID NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  source_check_id  UUID NOT NULL REFERENCES public.qc_checks(id) ON DELETE CASCADE,
  status           TEXT NOT NULL DEFAULT 'open'
                     CHECK (status IN ('open', 'in_progress', 'resolved')),
  assigned_to_name TEXT,
  resolution_notes TEXT,
  created_by       UUID NOT NULL REFERENCES auth.users(id),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at      TIMESTAMPTZ,
  UNIQUE (source_check_id)
);

ALTER TABLE public.qc_followups ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'qc_followups'
      AND policyname = 'qc_followups_restaurant_isolation'
  ) THEN
    CREATE POLICY qc_followups_restaurant_isolation
    ON public.qc_followups
    USING (
      restaurant_id = get_user_restaurant_id()
      OR has_any_role(ARRAY['super_admin'])
    );
  END IF;
END $$;

-- ─── Create Follow-up ───────────────────────────
CREATE OR REPLACE FUNCTION public.create_qc_followup(
  p_restaurant_id   UUID,
  p_source_check_id UUID,
  p_assigned_to_name TEXT DEFAULT NULL
) RETURNS public.qc_followups AS $$
DECLARE
  v_actor      public.users%ROWTYPE;
  v_check      public.qc_checks%ROWTYPE;
  v_created    public.qc_followups%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  SELECT * INTO v_check
  FROM public.qc_checks
  WHERE id = p_source_check_id
    AND restaurant_id = p_restaurant_id;

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
    p_restaurant_id, p_source_check_id, 'open',
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
      'restaurant_id', p_restaurant_id,
      'source_check_id', p_source_check_id,
      'assigned_to_name', v_created.assigned_to_name
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ─── Update Follow-up Status ────────────────────
CREATE OR REPLACE FUNCTION public.update_qc_followup_status(
  p_followup_id      UUID,
  p_restaurant_id    UUID,
  p_status           TEXT,
  p_resolution_notes TEXT DEFAULT NULL
) RETURNS public.qc_followups AS $$
DECLARE
  v_actor    public.users%ROWTYPE;
  v_existing public.qc_followups%ROWTYPE;
  v_updated  public.qc_followups%ROWTYPE;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_WRITE_FORBIDDEN';
  END IF;

  IF p_status NOT IN ('open', 'in_progress', 'resolved') THEN
    RAISE EXCEPTION 'QC_FOLLOWUP_STATUS_INVALID';
  END IF;

  SELECT * INTO v_existing
  FROM public.qc_followups
  WHERE id = p_followup_id
    AND restaurant_id = p_restaurant_id
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
      'restaurant_id', p_restaurant_id,
      'old_status', v_existing.status,
      'new_status', p_status,
      'resolution_notes', v_updated.resolution_notes
    )
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ─── Get Follow-ups ─────────────────────────────
CREATE OR REPLACE FUNCTION public.get_qc_followups(
  p_restaurant_id UUID,
  p_status_filter TEXT DEFAULT NULL
) RETURNS TABLE (
  followup_id       UUID,
  restaurant_id     UUID,
  source_check_id   UUID,
  status            TEXT,
  assigned_to_name  TEXT,
  resolution_notes  TEXT,
  created_at        TIMESTAMPTZ,
  updated_at        TIMESTAMPTZ,
  resolved_at       TIMESTAMPTZ,
  check_date        DATE,
  check_result      TEXT,
  check_note        TEXT,
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
     AND v_actor.restaurant_id <> p_restaurant_id THEN
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
  WHERE f.restaurant_id = p_restaurant_id
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

-- ─── QC Analytics ───────────────────────────────
CREATE OR REPLACE FUNCTION public.get_qc_analytics(
  p_restaurant_id UUID,
  p_from DATE,
  p_to DATE
) RETURNS TABLE (
  total_checks   BIGINT,
  pass_count     BIGINT,
  fail_count     BIGINT,
  na_count       BIGINT,
  pass_rate      NUMERIC,
  template_count BIGINT,
  coverage       NUMERIC,
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
     AND v_actor.restaurant_id <> p_restaurant_id THEN
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
       AND (qt.is_global = TRUE OR qt.restaurant_id = p_restaurant_id)
    )::BIGINT AS template_count,
    CASE
      WHEN (SELECT COUNT(*) FROM public.qc_templates qt
            WHERE qt.is_active = TRUE
              AND (qt.is_global = TRUE OR qt.restaurant_id = p_restaurant_id)) = 0
      THEN 0::NUMERIC
      ELSE ROUND(
        COUNT(*)::NUMERIC
        / ((SELECT COUNT(*) FROM public.qc_templates qt
            WHERE qt.is_active = TRUE
              AND (qt.is_global = TRUE OR qt.restaurant_id = p_restaurant_id))
           * v_days)::NUMERIC * 100,
        1
      )
    END AS coverage,
    (SELECT COUNT(*) FROM public.qc_followups f
     WHERE f.restaurant_id = p_restaurant_id
       AND f.status IN ('open', 'in_progress')
    )::BIGINT AS open_followups
  FROM public.qc_checks qc
  WHERE qc.restaurant_id = p_restaurant_id
    AND qc.check_date >= p_from
    AND qc.check_date <= p_to;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
