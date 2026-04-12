-- ============================================================================
-- Phase 2 Step 2 (Expand): add store compatibility aliases
-- Scope: POS-only expand stage. No renames, no drops of authoritative objects.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_user_store_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT public.get_user_restaurant_id()
$$;

CREATE VIEW public.stores AS
SELECT *
FROM public.restaurants;

CREATE VIEW public.public_store_profiles AS
SELECT *
FROM public.public_restaurant_profiles;

COMMIT;
