\set ON_ERROR_STOP on

DO $$
DECLARE
  v_missing integer;
BEGIN
  IF to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.restaurant_settings') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.order_items') IS NULL
     OR to_regclass('public.payments') IS NULL
     OR to_regclass('public.external_sales') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_REQUIRED_RELATION_MISSING';
  END IF;

  SELECT count(*) INTO v_missing
  FROM (
    VALUES
      ('restaurants', 'id'),
      ('restaurants', 'name'),
      ('restaurants', 'address'),
      ('restaurants', 'is_active'),
      ('restaurant_settings', 'restaurant_id'),
      ('orders', 'restaurant_id'),
      ('orders', 'status'),
      ('orders', 'created_at'),
      ('order_items', 'restaurant_id'),
      ('order_items', 'quantity'),
      ('order_items', 'unit_price'),
      ('order_items', 'item_type'),
      ('order_items', 'display_name'),
      ('order_items', 'paying_amount_inc_tax'),
      ('payments', 'restaurant_id'),
      ('payments', 'order_id'),
      ('payments', 'amount'),
      ('payments', 'is_revenue'),
      ('payments', 'created_at'),
      ('external_sales', 'restaurant_id'),
      ('external_sales', 'gross_amount'),
      ('external_sales', 'order_status'),
      ('external_sales', 'is_revenue'),
      ('external_sales', 'completed_at'),
      ('external_sales', 'created_at'),
      ('external_sales', 'updated_at')
  ) required(table_name, column_name)
  LEFT JOIN information_schema.columns column_info
    ON column_info.table_schema = 'public'
   AND column_info.table_name = required.table_name
   AND column_info.column_name = required.column_name
  WHERE column_info.column_name IS NULL;

  IF v_missing <> 0 THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_REQUIRED_COLUMN_MISSING: %', v_missing;
  END IF;

  IF to_regprocedure('public.process_payment(uuid,uuid,numeric,text)') IS NULL
     OR to_regprocedure('public.create_order(uuid,uuid,jsonb)') IS NULL
     OR to_regprocedure('public.add_items_to_order(uuid,uuid,jsonb)') IS NULL
     OR to_regprocedure('public.create_buffet_order(uuid,uuid,integer,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_AUTHORITATIVE_RPC_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc proc
    WHERE proc.oid = 'public.process_payment(uuid,uuid,numeric,text)'::regprocedure
      AND proc.prosecdef
  ) THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_PAYMENT_ATOMICITY_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class relation
    WHERE relation.oid = 'public.restaurants'::regclass
      AND relation.relkind NOT IN ('r', 'p')
  ) THEN
    RAISE EXCEPTION 'RESTAURANT_CUTOFF_RESTAURANTS_NOT_PHYSICAL';
  END IF;
END $$;

SELECT 'RESTAURANT_CUTOFF_PREFLIGHT_OK' AS result;
