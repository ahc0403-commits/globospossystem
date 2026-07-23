DO $$
BEGIN
  IF to_regclass('public.photo_objet_sales') IS NULL
     OR to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.users') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_OPS_LATEST_SALES_PREFLIGHT_TABLE_MISSING';
  END IF;

  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_OPS_LATEST_SALES_PREFLIGHT_SCOPE_HELPER_MISSING';
  END IF;
END;
$$;

SELECT 'Photo Ops latest-sales RPC preflight passed' AS result;
