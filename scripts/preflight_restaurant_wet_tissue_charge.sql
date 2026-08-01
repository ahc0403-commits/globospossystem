\set ON_ERROR_STOP on

DO $preflight$
DECLARE
  v_required_column text;
BEGIN
  IF to_regclass('public.order_items') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.payments') IS NULL
     OR to_regclass('public.users') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_WET_TISSUE_REQUIRED_TABLE_MISSING';
  END IF;

  FOREACH v_required_column IN ARRAY ARRAY[
    'restaurant_id', 'order_id', 'menu_item_id', 'item_type', 'label',
    'display_name', 'unit_price', 'quantity', 'status', 'vat_rate',
    'vat_amount', 'total_amount_ex_tax', 'paying_amount_inc_tax',
    'is_service_item'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_attribute
      WHERE attrelid = 'public.order_items'::regclass
        AND attname = v_required_column
        AND NOT attisdropped
    ) THEN
      RAISE EXCEPTION 'RESTAURANT_WET_TISSUE_REQUIRED_COLUMN_MISSING:%',
        v_required_column;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.order_items'::regclass
      AND conname = 'order_items_item_type_check'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.order_items'::regclass
      AND conname = 'order_items_item_type_menu_item_check'
  ) THEN
    RAISE EXCEPTION 'RESTAURANT_WET_TISSUE_BASE_CONSTRAINT_MISSING';
  END IF;

  IF to_regprocedure('public.is_super_admin()') IS NULL
     OR to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_WET_TISSUE_ACCESS_HELPER_MISSING';
  END IF;
END
$preflight$;

SELECT 'restaurant wet-tissue charge preflight passed' AS result;
