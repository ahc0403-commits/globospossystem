DO $$
DECLARE
  cancel_definition text := pg_get_functiondef('public.cancel_order(uuid,uuid,boolean)'::regprocedure);
  restore_definition text := pg_get_functiondef('public.restore_cancelled_order(uuid,uuid)'::regprocedure);
BEGIN
  IF position('ORDER_HAS_SERVED_QUANTITY_CANCEL_UNSERVED_ITEMS' in cancel_definition) > 0
     OR position('order_cancellation_ledger' in cancel_definition) = 0
     OR position('ORDER_HAS_PAYMENTS_USE_ADJUSTMENT' in cancel_definition) = 0
     OR position('v_actor.role = ''waiter''' in cancel_definition) = 0
     OR position('''ready'', ''served''' in cancel_definition) = 0
     OR NOT has_function_privilege('authenticated', 'public.cancel_order(uuid,uuid,boolean)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cancel_order(uuid,uuid,boolean)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cancel_order_pre_start_ready(uuid,uuid,boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'CASHIER_ORDER_CANCELLATION_VERIFICATION_FAILED';
  END IF;
  IF position('UPDATE public.orders' in restore_definition) = 0
     OR position('UPDATE public.orders' in restore_definition) > position('UPDATE public.order_items' in restore_definition) THEN
    RAISE EXCEPTION 'ORDER_RESTORE_TRIGGER_ORDER_INVALID';
  END IF;
END;
$$;
