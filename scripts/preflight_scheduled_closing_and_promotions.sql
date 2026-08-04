\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.daily_closings') IS NULL
     OR to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.order_items') IS NULL
     OR to_regclass('public.order_discounts') IS NULL
     OR to_regclass('public.payments') IS NULL
     OR to_regclass('public.inventory_items') IS NULL
     OR to_regclass('public.menu_items') IS NULL
     OR to_regclass('public.menu_categories') IS NULL THEN
    RAISE EXCEPTION 'SCHEDULED_CLOSING_PROMOTION_DEPENDENCY_MISSING';
  END IF;

  IF to_regprocedure('public.require_pos_admin_actor_for_store(uuid,text)') IS NULL
     OR to_regprocedure('public.calculate_order_discountable_total(uuid,uuid)') IS NULL
     OR to_regprocedure('public.user_accessible_stores(uuid)') IS NULL
     OR to_regprocedure('public.qr_get_menu(text)') IS NULL THEN
    RAISE EXCEPTION 'SCHEDULED_CLOSING_PROMOTION_FUNCTION_DEPENDENCY_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.daily_closings'::regclass
      AND contype = 'u'
      AND pg_get_constraintdef(oid) LIKE '%restaurant_id, closing_date%'
  ) THEN
    RAISE EXCEPTION 'DAILY_CLOSING_IDEMPOTENCY_CONSTRAINT_MISSING';
  END IF;
END
$preflight$;

SELECT 'scheduled closing and promotions preflight passed' AS result;
