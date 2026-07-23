BEGIN;

CREATE OR REPLACE FUNCTION public.upsert_photo_objet_inventory_item(
  p_store_id uuid,
  p_item_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_current_stock numeric DEFAULT 0
) RETURNS public.inventory_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_item public.inventory_items%ROWTYPE;
  v_name text := btrim(COALESCE(p_name, ''));
  v_current_stock numeric := COALESCE(p_current_stock, 0);
  v_action text;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_STORE_REQUIRED';
  END IF;

  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = true
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN ('photo_objet_master', 'super_admin') THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_WRITE_FORBIDDEN';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants store
    WHERE store.id = p_store_id
      AND store.brand_id =
        '77000000-0000-0000-0000-000000000001'::uuid
      AND store.is_active = true
  ) THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_STORE_FORBIDDEN';
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_NAME_REQUIRED';
  END IF;

  IF v_current_stock < 0 THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_STOCK_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items item
    WHERE item.restaurant_id = p_store_id
      AND lower(btrim(item.name)) = lower(v_name)
      AND (p_item_id IS NULL OR item.id <> p_item_id)
  ) THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_NAME_DUPLICATE';
  END IF;

  IF p_item_id IS NULL THEN
    INSERT INTO public.inventory_items (
      restaurant_id,
      name,
      quantity,
      unit,
      current_stock,
      updated_at
    )
    VALUES (
      p_store_id,
      v_name,
      v_current_stock,
      'ea',
      v_current_stock,
      now()
    )
    RETURNING * INTO v_item;
    v_action := 'photo_inventory_item_created';
  ELSE
    UPDATE public.inventory_items item
    SET name = v_name,
        quantity = v_current_stock,
        current_stock = v_current_stock,
        updated_at = now()
    WHERE item.id = p_item_id
      AND item.restaurant_id = p_store_id
    RETURNING item.* INTO v_item;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'PHOTO_INVENTORY_ITEM_NOT_FOUND';
    END IF;
    v_action := 'photo_inventory_item_updated';
  END IF;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  VALUES (
    auth.uid(),
    v_action,
    'inventory_items',
    v_item.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'name', v_item.name,
      'current_stock', v_item.current_stock,
      'unit', v_item.unit
    )
  );

  RETURN v_item;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_photo_objet_inventory_item(
  uuid,
  uuid,
  text,
  numeric
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_photo_objet_inventory_item(
  uuid,
  uuid,
  text,
  numeric
) TO authenticated;

COMMENT ON FUNCTION public.upsert_photo_objet_inventory_item(
  uuid,
  uuid,
  text,
  numeric
) IS
  'Creates or updates the simple per-store PHOTO OBJET inventory catalog after active-user, role, brand, and store-scope checks.';

COMMIT;
