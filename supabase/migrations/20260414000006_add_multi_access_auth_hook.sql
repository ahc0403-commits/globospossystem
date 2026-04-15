-- =============================================================================
-- Add multi-access auth helpers, auth hook claims, and claim refresh
-- Migration: 20260414000006_add_multi_access_auth_hook.sql
-- Depends on:
--   - 20260414000000_add_multi_access_schema.sql
--   - 20260414000004_add_multi_access_sync_functions.sql
--
-- Extends existing hook infrastructure from 20260412220000 without removing
-- the legacy fallback behavior. WeTax tax-axis claims remain intact.
-- =============================================================================

BEGIN;

-- ===========================================================================
-- 1. Helper functions
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.get_user_primary_store_id()
RETURNS uuid AS $$
  SELECT COALESCE(u.primary_store_id, u.restaurant_id)
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = true
  LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth;

COMMENT ON FUNCTION public.get_user_primary_store_id() IS
  'Returns the current user''s primary working store, falling back to users.restaurant_id during the transition period.';

CREATE OR REPLACE FUNCTION public.user_accessible_brands(uid uuid)
RETURNS SETOF uuid AS $$
  WITH explicit_brands AS (
    SELECT uba.brand_id
    FROM public.user_brand_access uba
    JOIN public.users u
      ON u.id = uba.user_id
    WHERE u.auth_id = uid
      AND u.is_active = true
      AND uba.is_active = true
  ),
  fallback_brand AS (
    SELECT u.brand_id
    FROM public.users u
    WHERE u.auth_id = uid
      AND u.is_active = true
      AND u.brand_id IS NOT NULL
  )
  SELECT DISTINCT brand_id
  FROM (
    SELECT brand_id FROM explicit_brands
    UNION
    SELECT brand_id FROM fallback_brand
  ) brand_scope
  WHERE brand_id IS NOT NULL;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth;

COMMENT ON FUNCTION public.user_accessible_brands(uuid) IS
  'Returns all active brand ids accessible to an auth user via user_brand_access plus the user''s fallback brand_id.';

CREATE OR REPLACE FUNCTION public.user_accessible_stores(uid uuid)
RETURNS SETOF uuid AS $$
  WITH explicit_store_access AS (
    SELECT usa.store_id
    FROM public.user_store_access usa
    JOIN public.users u
      ON u.id = usa.user_id
    WHERE u.auth_id = uid
      AND u.is_active = true
      AND usa.is_active = true
  ),
  fallback_store AS (
    SELECT COALESCE(u.primary_store_id, u.restaurant_id) AS store_id
    FROM public.users u
    WHERE u.auth_id = uid
      AND u.is_active = true
      AND COALESCE(u.primary_store_id, u.restaurant_id) IS NOT NULL
  )
  SELECT DISTINCT store_id
  FROM (
    SELECT store_id FROM explicit_store_access
    UNION
    SELECT store_id FROM fallback_store
  ) store_scope
  WHERE store_id IS NOT NULL;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth;

COMMENT ON FUNCTION public.user_accessible_stores(uuid) IS
  'Returns all active store ids accessible to an auth user via user_store_access plus the fallback primary/restaurant store during transition.';

CREATE OR REPLACE FUNCTION public.user_accessible_tax_entities(uid uuid)
RETURNS SETOF uuid AS $$
  SELECT DISTINCT r.tax_entity_id
  FROM public.user_accessible_stores(uid) s(store_id)
  JOIN public.restaurants r
    ON r.id = s.store_id
  WHERE r.tax_entity_id IS NOT NULL;
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, auth;

COMMENT ON FUNCTION public.user_accessible_tax_entities(uuid) IS
  'Returns all tax_entity ids reachable through the auth user''s accessible stores.';

-- ===========================================================================
-- 2. Claim refresh helper
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.refresh_user_claims(p_auth_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_user public.users%ROWTYPE;
  v_brand_ids uuid[];
  v_store_ids uuid[];
  v_tax_entity_ids uuid[];
  v_primary_store_id uuid;
  v_claims jsonb;
BEGIN
  SELECT *
  INTO v_user
  FROM public.users
  WHERE auth_id = p_auth_user_id
  LIMIT 1;

  IF NOT FOUND OR v_user.is_active IS NOT TRUE THEN
    v_claims := jsonb_build_object(
      'role', NULL,
      'brand_ids', '[]'::jsonb,
      'accessible_store_ids', '[]'::jsonb,
      'accessible_tax_entity_ids', '[]'::jsonb,
      'primary_store_id', NULL
    );
  ELSE
    v_brand_ids := ARRAY(SELECT * FROM public.user_accessible_brands(p_auth_user_id));
    v_store_ids := ARRAY(SELECT * FROM public.user_accessible_stores(p_auth_user_id));
    v_tax_entity_ids := ARRAY(SELECT * FROM public.user_accessible_tax_entities(p_auth_user_id));
    v_primary_store_id := COALESCE(v_user.primary_store_id, v_user.restaurant_id);

    v_claims := jsonb_build_object(
      'role', v_user.role,
      'brand_ids', to_jsonb(COALESCE(v_brand_ids, ARRAY[]::uuid[])),
      'accessible_store_ids', to_jsonb(COALESCE(v_store_ids, ARRAY[]::uuid[])),
      'accessible_tax_entity_ids', to_jsonb(COALESCE(v_tax_entity_ids, ARRAY[]::uuid[])),
      'primary_store_id', to_jsonb(v_primary_store_id)
    );
  END IF;

  UPDATE auth.users
  SET raw_app_meta_data =
    COALESCE(raw_app_meta_data, '{}'::jsonb)
    - 'role'
    - 'brand_ids'
    - 'accessible_store_ids'
    - 'accessible_tax_entity_ids'
    - 'primary_store_id'
    || v_claims
  WHERE id = p_auth_user_id;

  RETURN v_claims;
END;
$$;

COMMENT ON FUNCTION public.refresh_user_claims(uuid) IS
  'Recomputes and persists app metadata claims for an auth.users.id after access or role changes.';

-- ===========================================================================
-- 3. Auth hook claims
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb AS $$
DECLARE
  v_uid            uuid;
  v_user           public.users%ROWTYPE;
  v_brand_ids      uuid[];
  v_store_ids      uuid[];
  v_tax_entity_ids uuid[];
  v_primary_store  uuid;
BEGIN
  v_uid := (event->>'user_id')::uuid;

  SELECT *
  INTO v_user
  FROM public.users
  WHERE auth_id = v_uid
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN event;
  END IF;

  v_brand_ids      := ARRAY(SELECT * FROM public.user_accessible_brands(v_uid));
  v_store_ids      := ARRAY(SELECT * FROM public.user_accessible_stores(v_uid));
  v_tax_entity_ids := ARRAY(SELECT * FROM public.user_accessible_tax_entities(v_uid));
  v_primary_store  := COALESCE(v_user.primary_store_id, v_user.restaurant_id);

  event := jsonb_set(
    event,
    '{claims,app_metadata,role}',
    to_jsonb(v_user.role),
    true
  );
  event := jsonb_set(
    event,
    '{claims,app_metadata,brand_ids}',
    to_jsonb(COALESCE(v_brand_ids, ARRAY[]::uuid[])),
    true
  );
  event := jsonb_set(
    event,
    '{claims,app_metadata,accessible_store_ids}',
    to_jsonb(COALESCE(v_store_ids, ARRAY[]::uuid[])),
    true
  );
  event := jsonb_set(
    event,
    '{claims,app_metadata,accessible_tax_entity_ids}',
    to_jsonb(COALESCE(v_tax_entity_ids, ARRAY[]::uuid[])),
    true
  );
  event := jsonb_set(
    event,
    '{claims,app_metadata,primary_store_id}',
    to_jsonb(v_primary_store),
    true
  );

  RETURN event;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, auth;

COMMENT ON FUNCTION public.custom_access_token_hook(jsonb) IS
  'Supabase custom access token hook. Populates app_metadata claims: role, brand_ids[], accessible_store_ids[], accessible_tax_entity_ids[], primary_store_id. Register in Dashboard hooks. Existing table-lookup fallback remains available during transition.';

COMMIT;
