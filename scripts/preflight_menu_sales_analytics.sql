\set ON_ERROR_STOP on

DO $preflight$
DECLARE
  v_missing integer;
BEGIN
  IF to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.order_items') IS NULL
     OR to_regclass('public.payments') IS NULL
     OR to_regclass('public.payment_adjustments') IS NULL THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_REQUIRED_RELATION_MISSING';
  END IF;

  SELECT count(*) INTO v_missing
  FROM (
    VALUES
      ('restaurants', 'id'),
      ('restaurants', 'name'),
      ('restaurants', 'address'),
      ('restaurants', 'is_active'),
      ('orders', 'id'),
      ('orders', 'restaurant_id'),
      ('orders', 'status'),
      ('orders', 'sales_channel'),
      ('order_items', 'id'),
      ('order_items', 'restaurant_id'),
      ('order_items', 'order_id'),
      ('order_items', 'menu_item_id'),
      ('order_items', 'item_type'),
      ('order_items', 'status'),
      ('order_items', 'display_name'),
      ('order_items', 'label'),
      ('order_items', 'quantity'),
      ('order_items', 'paying_amount_inc_tax'),
      ('order_items', 'is_service_item'),
      ('order_items', 'created_at'),
      ('payments', 'order_id'),
      ('payments', 'restaurant_id'),
      ('payments', 'is_revenue'),
      ('payments', 'created_at'),
      ('payment_adjustments', 'restaurant_id'),
      ('payment_adjustments', 'amount'),
      ('payment_adjustments', 'created_at')
  ) required(table_name, column_name)
  LEFT JOIN information_schema.columns column_info
    ON column_info.table_schema = 'public'
   AND column_info.table_name = required.table_name
   AND column_info.column_name = required.column_name
  WHERE column_info.column_name IS NULL;

  IF v_missing <> 0 THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_REQUIRED_COLUMN_MISSING: %',
      v_missing;
  END IF;

  IF to_regprocedure(
       'public.require_admin_actor_for_restaurant(uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.process_payment(uuid,uuid,numeric,text)'
     ) IS NULL
     OR to_regprocedure('public.create_order(uuid,uuid,jsonb)') IS NULL
     OR to_regprocedure('public.add_items_to_order(uuid,uuid,jsonb)') IS NULL
     OR to_regprocedure(
       'public.create_buffet_order(uuid,uuid,integer,jsonb)'
     ) IS NULL THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_AUTHORITATIVE_RPC_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc proc
    WHERE proc.oid =
      'public.process_payment(uuid,uuid,numeric,text)'::regprocedure
      AND proc.prosecdef
  ) THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_PAYMENT_ATOMICITY_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class relation
    WHERE relation.oid = 'public.restaurants'::regclass
      AND relation.relkind NOT IN ('r', 'p')
  ) THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_RESTAURANTS_NOT_PHYSICAL';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_items'
      AND column_name = 'menu_item_id_snapshot'
  )
     OR to_regprocedure(
       'public.capture_order_item_menu_identity()'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_UNTRACKED_OBJECT_PRESENT';
  END IF;
END
$preflight$;

SELECT 'MENU_SALES_ANALYTICS_PREFLIGHT_OK' AS result;
