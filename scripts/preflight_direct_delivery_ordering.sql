\set ON_ERROR_STOP on

-- Production-only, read-only preflight for the isolated direct-delivery domain.
-- A partial/manual prior installation is rejected instead of being overwritten.
DO $gate$
DECLARE
  v_required regclass;
BEGIN
  FOREACH v_required IN ARRAY ARRAY[
    'public.restaurants'::regclass,
    'public.users'::regclass,
    'public.menu_items'::regclass,
    'public.orders'::regclass,
    'public.order_items'::regclass,
    'public.payments'::regclass,
    'public.sepay_transactions'::regclass,
    'storage.buckets'::regclass,
    'storage.objects'::regclass
  ] LOOP
    IF v_required IS NULL THEN
      RAISE EXCEPTION 'DIRECT_ORDER_BASE_OBJECT_MISSING';
    END IF;
  END LOOP;

  IF to_regprocedure('public.process_payment(uuid,uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_ANCHOR_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class class_row
    JOIN pg_namespace namespace_row
      ON namespace_row.oid = class_row.relnamespace
    WHERE namespace_row.nspname = 'public'
      AND (
        class_row.relname LIKE 'direct_order_%'
        OR class_row.relname LIKE 'direct_delivery_%'
      )
  ) OR EXISTS (
    SELECT 1
    FROM pg_proc procedure_row
    JOIN pg_namespace namespace_row
      ON namespace_row.oid = procedure_row.pronamespace
    WHERE namespace_row.nspname = 'public'
      AND (
        procedure_row.proname LIKE 'direct_order_%'
        OR procedure_row.proname LIKE 'direct_delivery_%'
      )
  ) OR EXISTS (
    SELECT 1 FROM storage.buckets WHERE id = 'direct-order-proofs'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PARTIAL_INSTALLATION_DETECTED';
  END IF;
END;
$gate$;

SELECT 'DIRECT_DELIVERY_ORDERING_PREFLIGHT_PASS' AS result;
