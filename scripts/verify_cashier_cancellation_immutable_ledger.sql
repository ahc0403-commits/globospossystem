DO $verify$
DECLARE
  v_cancel_order regprocedure := to_regprocedure(
    'public.cancel_order(uuid,uuid,boolean)'
  );
  v_cancel_item regprocedure := to_regprocedure(
    'public.cancel_order_item(uuid,uuid)'
  );
  v_order_definition text;
  v_item_definition text;
BEGIN
  IF to_regclass('public.order_cancellation_ledger') IS NULL THEN
    RAISE EXCEPTION 'CASHIER_CANCELLATION_VERIFY_FAILED: ledger missing';
  END IF;

  IF v_cancel_order IS NULL OR v_cancel_item IS NULL THEN
    RAISE EXCEPTION 'CASHIER_CANCELLATION_VERIFY_FAILED: RPC missing';
  END IF;

  SELECT pg_get_functiondef(v_cancel_order::oid) INTO v_order_definition;
  SELECT pg_get_functiondef(v_cancel_item::oid) INTO v_item_definition;

  IF position('''cashier''' IN v_order_definition) = 0
     OR position('ORDER_HAS_PAYMENTS_USE_ADJUSTMENT' IN v_order_definition) = 0
     OR position('order_cancellation_ledger' IN v_order_definition) = 0
     OR position('''cashier''' IN v_item_definition) = 0
     OR position('ORDER_HAS_PAYMENTS_USE_ADJUSTMENT' IN v_item_definition) = 0
     OR position('order_cancellation_ledger' IN v_item_definition) = 0 THEN
    RAISE EXCEPTION 'CASHIER_CANCELLATION_VERIFY_FAILED: RPC contract mismatch';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'order_cancellation_ledger_immutable'
      AND tgrelid = 'public.order_cancellation_ledger'::regclass
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'CASHIER_CANCELLATION_VERIFY_FAILED: immutable trigger missing';
  END IF;

  IF has_table_privilege('authenticated', 'public.order_cancellation_ledger', 'INSERT')
     OR has_table_privilege('authenticated', 'public.order_cancellation_ledger', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.order_cancellation_ledger', 'DELETE') THEN
    RAISE EXCEPTION 'CASHIER_CANCELLATION_VERIFY_FAILED: mutable client grant';
  END IF;
END;
$verify$;
