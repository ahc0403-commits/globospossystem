DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_inventory_ingredient_catalog(uuid)'::regprocedure
  ) INTO v_definition;

  IF position('photo_objet_master' IN v_definition) = 0
     OR position('photo_objet_store_operator' IN v_definition) = 0
     OR position('user_accessible_stores' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'PHOTO_OPS_INVENTORY_ACCESS_VERIFICATION_FAILED';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.get_inventory_ingredient_catalog(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PHOTO_OPS_INVENTORY_ANON_EXECUTE_NOT_REVOKED';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.get_inventory_ingredient_catalog(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PHOTO_OPS_INVENTORY_AUTHENTICATED_EXECUTE_MISSING';
  END IF;
END;
$$;

SELECT 'photo ops manager inventory access verification passed' AS result;
