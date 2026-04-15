-- =============================================================================
-- Backfill multi-access schema foundation
-- Migration: 20260414000002_backfill_multi_access_schema.sql
-- Depends on: 20260414000000_add_multi_access_schema.sql
--
-- Goals:
--   1. Seed users.brand_id from users.restaurant_id -> restaurants.brand_id
--   2. Seed users.primary_store_id from users.restaurant_id
--   3. Create direct user_store_access rows for active users
--   4. Create conservative brand access rows only for explicitly upper roles
--
-- Notes:
--   - Existing admin users remain store-scoped in this backfill
--   - super_admin remains a short-circuit role and is not expanded here
-- =============================================================================

BEGIN;

-- ===========================================================================
-- 1. Preflight checks
-- ===========================================================================
DO $$
DECLARE
  v_missing_restaurant_users integer;
  v_missing_brand_stores integer;
  v_invalid_restaurant_refs integer;
BEGIN
  SELECT COUNT(*)
    INTO v_missing_restaurant_users
  FROM public.users u
  WHERE u.is_active = true
    AND u.restaurant_id IS NULL;

  IF v_missing_restaurant_users > 0 THEN
    RAISE EXCEPTION
      'Backfill blocked: % active users are missing users.restaurant_id',
      v_missing_restaurant_users;
  END IF;

  SELECT COUNT(*)
    INTO v_invalid_restaurant_refs
  FROM public.users u
  LEFT JOIN public.restaurants r
    ON r.id = u.restaurant_id
  WHERE u.is_active = true
    AND u.restaurant_id IS NOT NULL
    AND r.id IS NULL;

  IF v_invalid_restaurant_refs > 0 THEN
    RAISE EXCEPTION
      'Backfill blocked: % active users reference missing restaurants',
      v_invalid_restaurant_refs;
  END IF;

  SELECT COUNT(*)
    INTO v_missing_brand_stores
  FROM public.restaurants r
  JOIN public.users u
    ON u.restaurant_id = r.id
  WHERE u.is_active = true
    AND r.brand_id IS NULL;

  IF v_missing_brand_stores > 0 THEN
    RAISE EXCEPTION
      'Backfill blocked: % active-user stores are missing restaurants.brand_id',
      v_missing_brand_stores;
  END IF;
END $$;

-- ===========================================================================
-- 2. users backfill
-- ===========================================================================
UPDATE public.users u
SET
  primary_store_id = COALESCE(u.primary_store_id, u.restaurant_id),
  brand_id = COALESCE(u.brand_id, r.brand_id)
FROM public.restaurants r
WHERE r.id = u.restaurant_id
  AND (
    u.primary_store_id IS NULL
    OR u.brand_id IS NULL
  );

-- ===========================================================================
-- 3. direct store access for active users
-- ===========================================================================
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
  u.id,
  u.primary_store_id,
  true,
  true,
  'direct',
  NULL,
  NULL
FROM public.users u
WHERE u.is_active = true
  AND u.primary_store_id IS NOT NULL
ON CONFLICT (user_id, store_id, source_type)
DO UPDATE SET
  is_primary = EXCLUDED.is_primary,
  is_active = true,
  updated_at = now();

-- ===========================================================================
-- 4. conservative brand access for existing upper roles only
--    Existing admin users remain store-scoped until explicit role migration.
-- ===========================================================================
INSERT INTO public.user_brand_access (
  user_id,
  brand_id,
  is_active,
  granted_by
)
SELECT
  u.id,
  u.brand_id,
  true,
  NULL
FROM public.users u
WHERE u.is_active = true
  AND u.brand_id IS NOT NULL
  AND u.role IN ('master_admin', 'photo_objet_master', 'brand_admin')
ON CONFLICT (user_id, brand_id)
DO UPDATE SET
  is_active = true,
  updated_at = now();

COMMIT;
