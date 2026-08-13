\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regprocedure(
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone)'
     ) IS NULL
     OR to_regprocedure(
       'public.require_admin_actor_for_restaurant(uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'MENU_SALES_COMBO_FILTER_BASE_CONTRACT_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_items'
      AND column_name = 'combo_components'
      AND data_type = 'jsonb'
  ) THEN
    RAISE EXCEPTION 'MENU_SALES_COMBO_FILTER_SNAPSHOT_MISSING';
  END IF;

  IF to_regprocedure(
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone,boolean)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'MENU_SALES_COMBO_FILTER_UNTRACKED_OBJECT_PRESENT';
  END IF;
END
$preflight$;

SELECT 'MENU_SALES_COMBO_FILTER_PREFLIGHT_OK' AS result;
