DO $$
BEGIN
  IF to_regclass('public.inventory_items') IS NULL
     OR to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.users') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SIMPLE_INVENTORY_PREFLIGHT_TABLE_MISSING';
  END IF;

  IF to_regprocedure('public.require_admin_actor_for_restaurant(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SIMPLE_INVENTORY_PREFLIGHT_SCOPE_HELPER_MISSING';
  END IF;
END;
$$;

SELECT 'Photo Objet simple inventory management preflight passed' AS result;
