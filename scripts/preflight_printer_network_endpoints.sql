\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.printer_destinations') IS NULL
     OR to_regclass('public.restaurants') IS NULL THEN
    RAISE EXCEPTION 'PRINTER_ENDPOINT_REQUIRED_RELATION_MISSING';
  END IF;

  IF (
    SELECT count(*)
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'printer_destinations'
      AND column_name IN (
        'id', 'restaurant_id', 'name', 'ip', 'port', 'purpose',
        'floor_label', 'is_active'
      )
  ) <> 8 THEN
    RAISE EXCEPTION 'PRINTER_ENDPOINT_REQUIRED_COLUMN_MISSING';
  END IF;

  IF to_regprocedure(
       'public.require_admin_actor_for_restaurant(uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.user_accessible_stores(uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'PRINTER_ENDPOINT_REQUIRED_FUNCTION_MISSING';
  END IF;
END
$preflight$;

SELECT 'PRINTER_NETWORK_ENDPOINT_PREFLIGHT_OK' AS result;
