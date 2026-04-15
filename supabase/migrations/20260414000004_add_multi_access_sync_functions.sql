-- =============================================================================
-- Add multi-access sync functions
-- Migration: 20260414000004_add_multi_access_sync_functions.sql
-- Depends on:
--   - 20260414000000_add_multi_access_schema.sql
--   - 20260414000002_backfill_multi_access_schema.sql
--
-- Delivers:
--   1. sync_user_store_access(user_id)
--   2. sync_brand_store_access(brand_id)
--   3. sync_all_store_access()
--
-- Rules:
--   - Only brand_inherited rows are recalculated
--   - direct rows are never modified by sync
--   - super_admin remains a short-circuit role outside physical expansion
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.sync_user_store_access(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user public.users%ROWTYPE;
BEGIN
  SELECT *
  INTO v_user
  FROM public.users
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_user.is_active IS NOT TRUE THEN
    UPDATE public.user_store_access
    SET
      is_active = false,
      updated_at = now()
    WHERE user_id = p_user_id
      AND source_type = 'brand_inherited'
      AND is_active = true;
    RETURN;
  END IF;

  INSERT INTO public.user_store_access (
    user_id,
    store_id,
    is_primary,
    is_active,
    source_type,
    source_brand_access_id,
    granted_by
  )
  SELECT
    v_user.id,
    r.id,
    false,
    true,
    'brand_inherited',
    uba.id,
    NULL
  FROM public.user_brand_access uba
  JOIN public.restaurants r
    ON r.brand_id = uba.brand_id
  WHERE uba.user_id = v_user.id
    AND uba.is_active = true
    AND r.is_active = true
    AND v_user.role <> 'super_admin'
  ON CONFLICT (user_id, store_id, source_type)
  DO UPDATE SET
    is_active = true,
    is_primary = false,
    source_brand_access_id = EXCLUDED.source_brand_access_id,
    updated_at = now();

  UPDATE public.user_store_access usa
  SET
    is_active = false,
    updated_at = now()
  WHERE usa.user_id = v_user.id
    AND usa.source_type = 'brand_inherited'
    AND usa.is_active = true
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_brand_access uba
      JOIN public.restaurants r
        ON r.brand_id = uba.brand_id
      WHERE uba.user_id = v_user.id
        AND uba.is_active = true
        AND r.is_active = true
        AND r.id = usa.store_id
        AND v_user.role <> 'super_admin'
    );
END;
$$;

COMMENT ON FUNCTION public.sync_user_store_access(uuid) IS
  'Recomputes brand-inherited store access rows for a single public.users.id. direct rows are preserved.';

CREATE OR REPLACE FUNCTION public.sync_brand_store_access(p_brand_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  FOR v_user_id IN
    SELECT DISTINCT u.id
    FROM public.users u
    JOIN public.user_brand_access uba
      ON uba.user_id = u.id
    WHERE uba.brand_id = p_brand_id
  LOOP
    PERFORM public.sync_user_store_access(v_user_id);
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.sync_brand_store_access(uuid) IS
  'Recomputes inherited store access for all users connected to a brand.';

CREATE OR REPLACE FUNCTION public.sync_all_store_access()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  FOR v_user_id IN
    SELECT id
    FROM public.users
  LOOP
    PERFORM public.sync_user_store_access(v_user_id);
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.sync_all_store_access() IS
  'Recomputes inherited store access for all users. Intended for backfill and operator recovery flows.';

COMMIT;
