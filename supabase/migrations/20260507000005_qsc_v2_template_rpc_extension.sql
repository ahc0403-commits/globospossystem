-- ============================================================
-- QSC v2 Wave 4c: template RPC extension
-- 2026-05-07
-- Scope:
-- - extend get_qc_templates with QSC template fields
-- - extend create_qc_template with optional QSC template params
-- - extend update_qc_template patch contract for QSC template fields
-- Notes:
-- - legacy params and legacy return columns remain at the front
-- - only additive QSC fields are introduced in this wave
-- ============================================================

DROP FUNCTION IF EXISTS public.get_qc_templates(UUID, TEXT);
DROP FUNCTION IF EXISTS public.create_qc_template(TEXT, TEXT, UUID, TEXT, INT, BOOLEAN);

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
  updated_at TIMESTAMPTZ,
  qsc_domain TEXT,
  requires_photo BOOLEAN,
  required_photo_count INTEGER,
  weight NUMERIC,
  sort_group TEXT,
  is_sv_required BOOLEAN
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
       AND NOT EXISTS (
         SELECT 1
         FROM public.user_accessible_stores(auth.uid()) s(store_id)
         WHERE s.store_id = p_store_id
       ) THEN
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
    qt.updated_at,
    qt.qsc_domain,
    qt.requires_photo,
    qt.required_photo_count,
    qt.weight,
    qt.sort_group,
    qt.is_sv_required
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
  p_is_global BOOLEAN DEFAULT FALSE,
  p_qsc_domain TEXT DEFAULT NULL,
  p_requires_photo BOOLEAN DEFAULT TRUE,
  p_required_photo_count INT DEFAULT 1,
  p_weight NUMERIC DEFAULT 1,
  p_sort_group TEXT DEFAULT NULL,
  p_is_sv_required BOOLEAN DEFAULT FALSE
) RETURNS public.qc_templates AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.qc_templates%ROWTYPE;
  v_category TEXT := NULLIF(btrim(COALESCE(p_category, '')), '');
  v_criteria TEXT := NULLIF(btrim(COALESCE(p_criteria_text, '')), '');
  v_photo TEXT := NULLIF(btrim(COALESCE(p_criteria_photo_url, '')), '');
  v_qsc_domain TEXT := NULLIF(lower(btrim(COALESCE(p_qsc_domain, ''))), '');
  v_sort_group TEXT := NULLIF(btrim(COALESCE(p_sort_group, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
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

  IF v_qsc_domain IS NOT NULL
     AND v_qsc_domain NOT IN ('quality', 'service', 'cleanliness') THEN
    RAISE EXCEPTION 'QC_TEMPLATE_QSC_DOMAIN_INVALID';
  END IF;

  IF p_required_photo_count IS NULL OR p_required_photo_count < 0 THEN
    RAISE EXCEPTION 'QC_TEMPLATE_REQUIRED_PHOTO_COUNT_INVALID';
  END IF;

  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WEIGHT_INVALID';
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
       AND NOT EXISTS (
         SELECT 1
         FROM public.user_accessible_stores(auth.uid()) s(store_id)
         WHERE s.store_id = p_store_id
       ) THEN
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
    updated_at,
    qsc_domain,
    requires_photo,
    required_photo_count,
    weight,
    sort_group,
    is_sv_required
  )
  VALUES (
    CASE WHEN p_is_global THEN NULL ELSE p_store_id END,
    v_category,
    v_criteria,
    v_photo,
    p_sort_order,
    p_is_global,
    now(),
    v_qsc_domain,
    COALESCE(p_requires_photo, TRUE),
    p_required_photo_count,
    p_weight,
    v_sort_group,
    COALESCE(p_is_sv_required, FALSE)
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
      'sort_order', v_created.sort_order,
      'qsc_domain', v_created.qsc_domain,
      'requires_photo', v_created.requires_photo,
      'required_photo_count', v_created.required_photo_count,
      'weight', v_created.weight,
      'sort_group', v_created.sort_group,
      'is_sv_required', v_created.is_sv_required
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
  v_qsc_domain TEXT;
  v_requires_photo BOOLEAN;
  v_required_photo_count INT;
  v_weight NUMERIC(5,2);
  v_sort_group TEXT;
  v_is_sv_required BOOLEAN;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
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
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = v_existing.restaurant_id
     ) THEN
    RAISE EXCEPTION 'QC_TEMPLATE_WRITE_FORBIDDEN';
  END IF;

  FOR v_key, v_value IN
    SELECT key, value FROM jsonb_each(v_patch)
  LOOP
    IF v_key NOT IN (
      'category',
      'criteria_text',
      'criteria_photo_url',
      'sort_order',
      'qsc_domain',
      'requires_photo',
      'required_photo_count',
      'weight',
      'sort_group',
      'is_sv_required'
    ) THEN
      RAISE EXCEPTION 'QC_TEMPLATE_PATCH_UNSUPPORTED';
    END IF;
  END LOOP;

  v_category := v_existing.category;
  v_text := v_existing.criteria_text;
  v_photo := v_existing.criteria_photo_url;
  v_sort_order := v_existing.sort_order;
  v_qsc_domain := v_existing.qsc_domain;
  v_requires_photo := COALESCE(v_existing.requires_photo, TRUE);
  v_required_photo_count := COALESCE(v_existing.required_photo_count, 1);
  v_weight := COALESCE(v_existing.weight, 1);
  v_sort_group := v_existing.sort_group;
  v_is_sv_required := COALESCE(v_existing.is_sv_required, FALSE);

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

  IF v_patch ? 'qsc_domain' THEN
    v_qsc_domain := NULLIF(lower(btrim(COALESCE(v_patch->>'qsc_domain', ''))), '');
    IF v_qsc_domain IS NOT NULL
       AND v_qsc_domain NOT IN ('quality', 'service', 'cleanliness') THEN
      RAISE EXCEPTION 'QC_TEMPLATE_QSC_DOMAIN_INVALID';
    END IF;
    IF v_qsc_domain IS DISTINCT FROM v_existing.qsc_domain THEN
      v_changed_fields := array_append(v_changed_fields, 'qsc_domain');
      v_old_values := v_old_values || jsonb_build_object('qsc_domain', v_existing.qsc_domain);
      v_new_values := v_new_values || jsonb_build_object('qsc_domain', v_qsc_domain);
    END IF;
  END IF;

  IF v_patch ? 'requires_photo' THEN
    BEGIN
      v_requires_photo := (v_patch->>'requires_photo')::BOOLEAN;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'QC_TEMPLATE_REQUIRES_PHOTO_INVALID';
    END;
    IF v_requires_photo IS DISTINCT FROM v_existing.requires_photo THEN
      v_changed_fields := array_append(v_changed_fields, 'requires_photo');
      v_old_values := v_old_values || jsonb_build_object('requires_photo', v_existing.requires_photo);
      v_new_values := v_new_values || jsonb_build_object('requires_photo', v_requires_photo);
    END IF;
  END IF;

  IF v_patch ? 'required_photo_count' THEN
    BEGIN
      v_required_photo_count := (v_patch->>'required_photo_count')::INT;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'QC_TEMPLATE_REQUIRED_PHOTO_COUNT_INVALID';
    END;
    IF v_required_photo_count < 0 THEN
      RAISE EXCEPTION 'QC_TEMPLATE_REQUIRED_PHOTO_COUNT_INVALID';
    END IF;
    IF v_required_photo_count IS DISTINCT FROM v_existing.required_photo_count THEN
      v_changed_fields := array_append(v_changed_fields, 'required_photo_count');
      v_old_values := v_old_values || jsonb_build_object('required_photo_count', v_existing.required_photo_count);
      v_new_values := v_new_values || jsonb_build_object('required_photo_count', v_required_photo_count);
    END IF;
  END IF;

  IF v_patch ? 'weight' THEN
    BEGIN
      v_weight := (v_patch->>'weight')::NUMERIC(5,2);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'QC_TEMPLATE_WEIGHT_INVALID';
    END;
    IF v_weight <= 0 THEN
      RAISE EXCEPTION 'QC_TEMPLATE_WEIGHT_INVALID';
    END IF;
    IF v_weight IS DISTINCT FROM v_existing.weight THEN
      v_changed_fields := array_append(v_changed_fields, 'weight');
      v_old_values := v_old_values || jsonb_build_object('weight', v_existing.weight);
      v_new_values := v_new_values || jsonb_build_object('weight', v_weight);
    END IF;
  END IF;

  IF v_patch ? 'sort_group' THEN
    v_sort_group := NULLIF(btrim(COALESCE(v_patch->>'sort_group', '')), '');
    IF v_sort_group IS DISTINCT FROM v_existing.sort_group THEN
      v_changed_fields := array_append(v_changed_fields, 'sort_group');
      v_old_values := v_old_values || jsonb_build_object('sort_group', v_existing.sort_group);
      v_new_values := v_new_values || jsonb_build_object('sort_group', v_sort_group);
    END IF;
  END IF;

  IF v_patch ? 'is_sv_required' THEN
    BEGIN
      v_is_sv_required := (v_patch->>'is_sv_required')::BOOLEAN;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'QC_TEMPLATE_SV_REQUIRED_INVALID';
    END;
    IF v_is_sv_required IS DISTINCT FROM v_existing.is_sv_required THEN
      v_changed_fields := array_append(v_changed_fields, 'is_sv_required');
      v_old_values := v_old_values || jsonb_build_object('is_sv_required', v_existing.is_sv_required);
      v_new_values := v_new_values || jsonb_build_object('is_sv_required', v_is_sv_required);
    END IF;
  END IF;

  UPDATE public.qc_templates
  SET category = v_category,
      criteria_text = v_text,
      criteria_photo_url = v_photo,
      sort_order = v_sort_order,
      qsc_domain = v_qsc_domain,
      requires_photo = v_requires_photo,
      required_photo_count = v_required_photo_count,
      weight = v_weight,
      sort_group = v_sort_group,
      is_sv_required = v_is_sv_required,
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
