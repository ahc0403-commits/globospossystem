\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.order_cancellation_ledger') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.order_items') IS NULL
     OR to_regclass('public.restaurants') IS NULL
     OR to_regprocedure('public.is_super_admin()') IS NULL
     OR to_regprocedure('public.user_accessible_stores(uuid)') IS NULL
     OR to_regprocedure('public.recalc_order_status(uuid)') IS NULL
     OR to_regprocedure(
       'public.void_active_order_discount_for_item_change(uuid,uuid,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'CANCELLATION_RESTORE_REQUIRED_OBJECT_MISSING';
  END IF;
END
$preflight$;

SELECT 'Cancellation restore/live sales preflight passed' AS result;
