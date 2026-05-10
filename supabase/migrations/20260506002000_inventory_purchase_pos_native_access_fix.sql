-- ============================================================
-- Inventory Purchase POS-Native Access Fix
-- 2026-05-06
--
-- POS inventory purchase contracts must not depend on Office-only identity
-- tables. Office review calls enter through the Office bridge with service_role.
-- ============================================================

CREATE OR REPLACE FUNCTION public.can_access_inventory_purchase_store(
  p_store_id UUID
) RETURNS BOOLEAN AS $$
BEGIN
  IF p_store_id IS NULL THEN
    RETURN FALSE;
  END IF;

  IF auth.role() = 'service_role' THEN
    RETURN TRUE;
  END IF;

  IF public.has_any_role(ARRAY['super_admin']) THEN
    RETURN TRUE;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) s(store_id)
    WHERE s.store_id = p_store_id
  ) THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.can_office_review_inventory_purchase_store(
  p_store_id UUID
) RETURNS BOOLEAN AS $$
BEGIN
  IF p_store_id IS NULL THEN
    RETURN FALSE;
  END IF;

  IF auth.role() = 'service_role' THEN
    RETURN TRUE;
  END IF;

  IF public.has_any_role(ARRAY['super_admin']) THEN
    RETURN TRUE;
  END IF;

  RETURN FALSE;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;
