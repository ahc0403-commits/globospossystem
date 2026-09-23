DO $preflight_non_revenue_checkout_concurrency$
BEGIN
  IF to_regprocedure(
       'public.process_payment(uuid,uuid,numeric,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_PREFLIGHT_PAYMENT_MISSING';
  END IF;

  IF to_regprocedure(
       'public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_PREFLIGHT_PAYMENT_CORE_MISSING';
  END IF;

  IF to_regprocedure(
       'public.process_non_revenue_payment(uuid,uuid,numeric,text,text,text,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_PREFLIGHT_CHECKOUT_MISSING';
  END IF;

  IF to_regprocedure(
       'public.add_items_to_order(uuid,uuid,jsonb)'
     ) IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_PREFLIGHT_STAFF_ORDER_MISSING';
  END IF;

  IF to_regprocedure(
       'public.qr_place_order(text,jsonb,uuid,boolean,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_CONCURRENCY_PREFLIGHT_QR_ORDER_MISSING';
  END IF;
END;
$preflight_non_revenue_checkout_concurrency$;

SELECT 'non-revenue checkout concurrency preflight passed' AS result;
