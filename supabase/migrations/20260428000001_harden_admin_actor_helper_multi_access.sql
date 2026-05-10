-- ============================================================
-- Harden admin actor helper for multi-access rollout
-- 2026-04-28
-- Scope:
-- - require_admin_actor_for_restaurant role gate + scope check
-- ============================================================

CREATE OR REPLACE FUNCTION public.require_admin_actor_for_restaurant(
  p_restaurant_id UUID
) RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_restaurant_id
     ) THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;

  RETURN v_actor;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
