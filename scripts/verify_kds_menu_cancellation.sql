DO $$
DECLARE
  restore_definition text := pg_get_functiondef('public.restore_cancelled_order_item(uuid,uuid)'::regprocedure);
  definition text := pg_get_functiondef('public.cancel_order_item(uuid,uuid)'::regprocedure);
BEGIN
  IF position('order_cancellation_ledger' in definition) = 0
     OR position('ORDER_HAS_PAYMENTS_USE_ADJUSTMENT' in definition) = 0
     OR position('''ready'', ''served''' in definition) = 0
     OR position('ITEM_HAS_SERVED_QUANTITY_USE_UNSERVED_CANCELLATION' in definition) > 0
     OR NOT has_function_privilege('authenticated', 'public.cancel_order_item(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cancel_order_item(uuid,uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cashier_cancel_unserved_v1(uuid,uuid,integer,text,uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cancel_order_item_pre_start_ready(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'KDS_MENU_CANCELLATION_VERIFICATION_FAILED';
  END IF;
  IF position('UPDATE public.orders' in restore_definition) = 0
     OR position('UPDATE public.orders' in restore_definition) >
        position('UPDATE public.order_items' in restore_definition) THEN
    RAISE EXCEPTION 'KDS_MENU_RESTORE_TRIGGER_ORDER_INVALID';
  END IF;
END;
$$;
