DO $$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure('public.get_photo_ops_latest_sales()') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_OPS_LATEST_SALES_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.get_photo_ops_latest_sales()'::regprocedure
  ) INTO v_definition;

  IF position('user_accessible_stores' IN v_definition) = 0
     OR position('photo_objet_master' IN v_definition) = 0
     OR position('max(s.sale_date)' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'PHOTO_OPS_LATEST_SALES_RPC_INVALID';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.get_photo_ops_latest_sales()',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PHOTO_OPS_LATEST_SALES_ANON_EXECUTE_NOT_REVOKED';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.get_photo_ops_latest_sales()',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PHOTO_OPS_LATEST_SALES_AUTH_EXECUTE_MISSING';
  END IF;
END;
$$;

SELECT 'Photo Ops latest-sales RPC verification passed' AS result;
