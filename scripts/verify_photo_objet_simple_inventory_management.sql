DO $$
DECLARE
  v_definition text;
  v_security_definer boolean;
  v_config text[];
BEGIN
  IF to_regprocedure(
    'public.upsert_photo_objet_inventory_item(uuid,uuid,text,numeric)'
  ) IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SIMPLE_INVENTORY_VERIFY_FUNCTION_MISSING';
  END IF;

  SELECT
    pg_get_functiondef(proc.oid),
    proc.prosecdef,
    proc.proconfig
  INTO v_definition, v_security_definer, v_config
  FROM pg_proc proc
  JOIN pg_namespace namespace ON namespace.oid = proc.pronamespace
  WHERE namespace.nspname = 'public'
    AND proc.oid =
      'public.upsert_photo_objet_inventory_item(uuid,uuid,text,numeric)'::regprocedure;

  IF NOT v_security_definer THEN
    RAISE EXCEPTION 'PHOTO_SIMPLE_INVENTORY_VERIFY_SECURITY_DEFINER_MISSING';
  END IF;

  IF NOT (
    'search_path=public, auth, pg_catalog' = ANY(COALESCE(v_config, ARRAY[]::text[]))
  ) THEN
    RAISE EXCEPTION 'PHOTO_SIMPLE_INVENTORY_VERIFY_SEARCH_PATH_MISSING';
  END IF;

  IF position('photo_objet_master' IN v_definition) = 0
     OR position('require_admin_actor_for_restaurant' IN v_definition) = 0
     OR position('77000000-0000-0000-0000-000000000001' IN v_definition) = 0
     OR position('audit_logs' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'PHOTO_SIMPLE_INVENTORY_VERIFY_GUARDS_MISSING';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.upsert_photo_objet_inventory_item(uuid,uuid,text,numeric)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PHOTO_SIMPLE_INVENTORY_VERIFY_ANON_EXECUTE_NOT_REVOKED';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.upsert_photo_objet_inventory_item(uuid,uuid,text,numeric)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PHOTO_SIMPLE_INVENTORY_VERIFY_AUTH_EXECUTE_MISSING';
  END IF;
END;
$$;

SELECT 'Photo Objet simple inventory management verification passed' AS result;
