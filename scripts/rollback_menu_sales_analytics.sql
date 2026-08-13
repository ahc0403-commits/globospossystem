\set ON_ERROR_STOP on

DROP FUNCTION IF EXISTS public.get_store_menu_sales_analytics(
  uuid,
  timestamptz,
  timestamptz
);

DROP TRIGGER IF EXISTS capture_order_item_menu_identity_trigger
  ON public.order_items;
DROP FUNCTION IF EXISTS public.capture_order_item_menu_identity();

ALTER TABLE public.order_items
  DROP COLUMN IF EXISTS menu_item_id_snapshot;

DO $rollback$
DECLARE
  v_missing integer;
BEGIN
  IF to_regprocedure(
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.capture_order_item_menu_identity()'
     ) IS NOT NULL
     OR EXISTS (
       SELECT 1
       FROM pg_trigger trigger_row
       WHERE trigger_row.tgname =
         'capture_order_item_menu_identity_trigger'
         AND NOT trigger_row.tgisinternal
     )
     OR EXISTS (
       SELECT 1
       FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'order_items'
         AND column_name = 'menu_item_id_snapshot'
     ) THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_ROLLBACK_OBJECT_REMAINS';
  END IF;

  IF to_regprocedure(
       'public.process_payment(uuid,uuid,numeric,text)'
     ) IS NULL
     OR to_regprocedure('public.create_order(uuid,uuid,jsonb)') IS NULL
     OR to_regprocedure('public.add_items_to_order(uuid,uuid,jsonb)') IS NULL
     OR to_regprocedure(
       'public.create_buffet_order(uuid,uuid,integer,jsonb)'
     ) IS NULL THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_ROLLBACK_CORE_POS_DAMAGED';
  END IF;

  SELECT count(*) INTO v_missing
  FROM (
    VALUES
      ('restaurants', 'id'),
      ('restaurants', 'name'),
      ('restaurants', 'address'),
      ('restaurants', 'is_active')
  ) required(table_name, column_name)
  LEFT JOIN information_schema.columns column_info
    ON column_info.table_schema = 'public'
   AND column_info.table_name = required.table_name
   AND column_info.column_name = required.column_name
  WHERE column_info.column_name IS NULL;
  IF v_missing <> 0 THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_ROLLBACK_OFFICE_CONTRACT_DAMAGED';
  END IF;
END
$rollback$;

SELECT 'MENU_SALES_ANALYTICS_ROLLBACK_OK' AS result;
