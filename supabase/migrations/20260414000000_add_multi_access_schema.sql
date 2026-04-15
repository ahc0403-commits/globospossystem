-- =============================================================================
-- Add multi-access schema foundation
-- Migration: 20260414000000_add_multi_access_schema.sql
-- Scope:
--   - Additive schema only
--   - No existing RLS policy rewrites
--   - No auth hook changes yet
--   - No Flutter consumer changes yet
--
-- Delivers:
--   1. users.brand_id
--   2. users.primary_store_id
--   3. user_brand_access
--   4. user_store_access
--
-- Notes:
--   - users.restaurant_id remains the fallback single-store field for now
--   - restaurants remains the physical store table in this transition phase
-- =============================================================================

BEGIN;

-- ===========================================================================
-- 1. users extensions
-- ===========================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'users'
      AND column_name = 'brand_id'
  ) THEN
    ALTER TABLE public.users
      ADD COLUMN brand_id uuid REFERENCES public.brands(id);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'users'
      AND column_name = 'primary_store_id'
  ) THEN
    ALTER TABLE public.users
      ADD COLUMN primary_store_id uuid REFERENCES public.restaurants(id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_users_brand_id
  ON public.users(brand_id);

CREATE INDEX IF NOT EXISTS idx_users_primary_store_id
  ON public.users(primary_store_id);

COMMENT ON COLUMN public.users.brand_id IS
  'Primary brand affiliation for the user. Added for the brand/store multi-access model. Nullable during transition and backfilled later.';

COMMENT ON COLUMN public.users.primary_store_id IS
  'Primary working store for the user. restaurants remains the physical store table during the transition. Nullable during transition and backfilled later.';

-- ===========================================================================
-- 2. user_brand_access
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.user_brand_access (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  brand_id uuid NOT NULL REFERENCES public.brands(id) ON DELETE CASCADE,
  is_active boolean NOT NULL DEFAULT true,
  granted_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_brand_access_unique UNIQUE (user_id, brand_id)
);

CREATE INDEX IF NOT EXISTS idx_user_brand_access_user_active
  ON public.user_brand_access(user_id, is_active);

CREATE INDEX IF NOT EXISTS idx_user_brand_access_brand_active
  ON public.user_brand_access(brand_id, is_active);

COMMENT ON TABLE public.user_brand_access IS
  'Authoritative brand-scope access table. Defines which brands a user can access in the multi-access model.';

COMMENT ON COLUMN public.user_brand_access.is_active IS
  'Soft-disable flag for brand access grants. Rows are preserved for auditability.';

ALTER TABLE public.user_brand_access ENABLE ROW LEVEL SECURITY;

-- ===========================================================================
-- 3. user_store_access
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.user_store_access (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  store_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  is_primary boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  source_type text NOT NULL
    CHECK (source_type IN ('direct', 'brand_inherited')),
  source_brand_access_id uuid REFERENCES public.user_brand_access(id) ON DELETE SET NULL,
  granted_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_store_access_unique UNIQUE (user_id, store_id, source_type)
);

CREATE INDEX IF NOT EXISTS idx_user_store_access_user_active
  ON public.user_store_access(user_id, is_active);

CREATE INDEX IF NOT EXISTS idx_user_store_access_store_active
  ON public.user_store_access(store_id, is_active);

CREATE INDEX IF NOT EXISTS idx_user_store_access_source_brand_access_id
  ON public.user_store_access(source_brand_access_id);

COMMENT ON TABLE public.user_store_access IS
  'Authoritative final store-scope access table. RLS and Flutter consumers will ultimately resolve access at the store level from this table.';

COMMENT ON COLUMN public.user_store_access.is_primary IS
  'Marks the user''s primary working store access row. Distinct from broader multi-store visibility.';

COMMENT ON COLUMN public.user_store_access.source_type IS
  'direct = explicitly granted store access; brand_inherited = derived from an active brand access grant.';

ALTER TABLE public.user_store_access ENABLE ROW LEVEL SECURITY;

COMMIT;
