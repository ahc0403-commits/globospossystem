-- Allow store managers and cashiers to change only the operational
-- availability flag used for sold-out menu handling.

CREATE OR REPLACE FUNCTION public.set_menu_item_availability(
  p_item_id uuid,
  p_is_available boolean
) RETURNS public.menu_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.menu_items%ROWTYPE;
  v_updated public.menu_items%ROWTYPE;
BEGIN
  IF p_item_id IS NULL OR p_is_available IS NULL THEN
    RAISE EXCEPTION 'MENU_AVAILABILITY_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_items
  WHERE id = p_item_id
    AND is_archived = false
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'MENU_AVAILABILITY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) access(store_id)
       WHERE access.store_id = v_existing.restaurant_id
     ) THEN
    RAISE EXCEPTION 'MENU_AVAILABILITY_FORBIDDEN';
  END IF;

  UPDATE public.menu_items
  SET is_available = p_is_available,
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF v_existing.is_available IS DISTINCT FROM v_updated.is_available THEN
    INSERT INTO public.audit_logs (
      actor_id,
      action,
      entity_type,
      entity_id,
      details
    ) VALUES (
      auth.uid(),
      'set_menu_item_availability',
      'menu_items',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'old_is_available', v_existing.is_available,
        'new_is_available', v_updated.is_available,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public.set_menu_item_availability(uuid, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_menu_item_availability(uuid, boolean)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.set_menu_item_availability(uuid, boolean) IS
  'Store-scoped operational sold-out toggle for cashier and admin-like roles. Only menu_items.is_available is mutable.';
