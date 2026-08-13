\set ON_ERROR_STOP on

DROP FUNCTION IF EXISTS public.get_store_menu_sales_analytics(
  uuid,
  timestamp with time zone,
  timestamp with time zone,
  boolean
);

DO $rollback$
BEGIN
  IF to_regprocedure(
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone,boolean)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'MENU_SALES_COMBO_FILTER_ROLLBACK_FAILED';
  END IF;

  IF to_regprocedure(
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone)'
     ) IS NULL
     OR to_regprocedure('public.process_payment(uuid,uuid,numeric,text)') IS NULL
     OR to_regclass('public.restaurants') IS NULL THEN
    RAISE EXCEPTION 'MENU_SALES_COMBO_FILTER_ROLLBACK_CORE_POS_DAMAGED';
  END IF;
END
$rollback$;

SELECT 'MENU_SALES_COMBO_FILTER_ROLLBACK_OK' AS result;
