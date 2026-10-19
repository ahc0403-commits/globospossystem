DO $verify_non_revenue_checkout_concurrency$
DECLARE
  v_payment_definition text;
  v_checkout_definition text;
  v_staff_order_definition text;
  v_qr_order_definition text;
BEGIN
  IF to_regclass(
       'public.non_revenue_checkout_20260923010000_backup'
     ) IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_VERIFY_BACKUP_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.process_payment(uuid,uuid,numeric,text)'::regprocedure
  ) INTO v_payment_definition;

  SELECT pg_get_functiondef(
    'public.process_non_revenue_payment(uuid,uuid,numeric,text,text,text,text)'::regprocedure
  ) INTO v_checkout_definition;

  SELECT pg_get_functiondef(
    'public.add_items_to_order(uuid,uuid,jsonb)'::regprocedure
  ) INTO v_staff_order_definition;

  SELECT pg_get_functiondef(
    'public.qr_place_order(text,jsonb,uuid,boolean,uuid)'::regprocedure
  ) INTO v_qr_order_definition;

  IF position('SERVICE_TOTAL_CHANGED' IN v_payment_definition) = 0
     OR position(
       'process_payment_before_promotion_read_split'
       IN v_payment_definition
     ) = 0 THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_VERIFY_SERVICE_EXACTNESS_MISSING';
  END IF;

  IF position('v_resuming' IN v_checkout_definition) = 0
     OR position('is_revenue IS DISTINCT FROM false' IN v_checkout_definition) = 0
     OR position('NON_REVENUE_AFTER_PAYMENT' IN v_checkout_definition) = 0 THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_VERIFY_RECOVERY_GUARD_MISSING';
  END IF;

  IF position(
       'ORDER_NON_REVENUE_PAYMENT_STARTED'
       IN v_staff_order_definition
     ) = 0
     OR position('FOR UPDATE' IN v_staff_order_definition) = 0 THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_VERIFY_STAFF_GUARD_MISSING';
  END IF;

  IF position('QR_ORDER_PAYMENT_IN_PROGRESS' IN v_qr_order_definition) = 0
     OR position('FOR UPDATE' IN v_qr_order_definition) = 0
     OR position('qr_order_batches' IN v_qr_order_definition) = 0 THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_VERIFY_QR_GUARD_MISSING';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.add_items_to_order_before_non_revenue_guard(uuid,uuid,jsonb)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.add_items_to_order_before_non_revenue_guard(uuid,uuid,jsonb)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'service_role',
       'public.add_items_to_order_before_non_revenue_guard(uuid,uuid,jsonb)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.qr_place_order_before_non_revenue_guard(text,jsonb,uuid,boolean,uuid)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated',
       'public.qr_place_order_before_non_revenue_guard(text,jsonb,uuid,boolean,uuid)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'service_role',
       'public.qr_place_order_before_non_revenue_guard(text,jsonb,uuid,boolean,uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_VERIFY_PRIVATE_CORE_EXPOSED';
  END IF;
END;
$verify_non_revenue_checkout_concurrency$;

SELECT 'non-revenue checkout concurrency verification passed' AS result;
