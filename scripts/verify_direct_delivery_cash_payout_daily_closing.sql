\set ON_ERROR_STOP on
DO $verify$
DECLARE v_definition text; v_function text;
BEGIN
  IF EXISTS (SELECT 1 FROM public.direct_order_dispatches
    WHERE actual_grab_fee IS NOT NULL AND cash_paid_at IS NULL) THEN
    RAISE EXCEPTION 'CASH_PAYOUT_BACKFILL_INCOMPLETE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='daily_closings'
      AND column_name='delivery_cash_payout' AND is_nullable='NO') THEN
    RAISE EXCEPTION 'CASH_PAYOUT_COLUMN_MISSING';
  END IF;
  SELECT pg_get_functiondef('public.direct_order_set_dispatch(uuid,uuid,text,numeric)'::regprocedure)
    INTO v_definition;
  IF position('DIRECT_ORDER_CASH_PAYOUT_LOCKED' IN v_definition)=0
    OR position('p_actual_grab_fee IS NULL' IN v_definition)=0
    OR position('direct_order_require_actor' IN v_definition)=0
    OR position('direct_delivery_fulfillment_tickets' IN v_definition)>0 THEN
    RAISE EXCEPTION 'CASH_PAYOUT_DISPATCH_CONTRACT_INVALID';
  END IF;
  FOREACH v_function IN ARRAY ARRAY[
    'public.direct_order_set_dispatch(uuid,uuid,text,numeric)',
    'public.get_daily_closing_cash_preview(uuid,date)',
    'public.create_daily_closing(uuid,text,jsonb,numeric,date)',
    'public.get_daily_closing_days(uuid,integer)'
  ] LOOP
    IF has_function_privilege('anon',v_function,'EXECUTE')
      OR NOT has_function_privilege('authenticated',v_function,'EXECUTE') THEN
      RAISE EXCEPTION 'CASH_PAYOUT_RPC_GRANTS_INVALID: %',v_function;
    END IF;
  END LOOP;
  SELECT pg_get_functiondef('public.create_daily_closing(uuid,text,jsonb,numeric,date)'::regprocedure)
    INTO v_definition;
  IF position('p_opening_cash_amount + v_payments_cash - v_delivery_cash_payout' IN v_definition)=0
    OR position('require_pos_admin_actor_for_store' IN v_definition)=0 THEN
    RAISE EXCEPTION 'CASH_PAYOUT_CLOSING_CONTRACT_INVALID';
  END IF;
END;
$verify$;
SELECT 'DIRECT_DELIVERY_CASH_PAYOUT_VERIFY_PASS' AS result;

