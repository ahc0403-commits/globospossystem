DO $verify$
DECLARE
  v_item_definition text;
  v_order_definition text;
BEGIN
  IF to_regprocedure('public.complete_kitchen_order(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'KITCHEN_DIRECT_COMPLETION_VERIFY_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.update_order_item_status(uuid,uuid,text)'::regprocedure
  ) INTO v_item_definition;
  IF v_item_definition NOT LIKE '%v_item.status = ''preparing'' AND p_new_status = ''served''%'
     OR v_item_definition LIKE '%v_item.status = ''preparing'' AND p_new_status = ''ready''%' THEN
    RAISE EXCEPTION 'KITCHEN_DIRECT_COMPLETION_VERIFY_ITEM_FLOW_INCORRECT';
  END IF;

  SELECT pg_get_functiondef(
    'public.complete_kitchen_order(uuid,uuid)'::regprocedure
  ) INTO v_order_definition;
  IF v_order_definition NOT LIKE '%status IN (''pending'', ''preparing'', ''ready'')%'
     OR v_order_definition NOT LIKE '%SET status = ''served''%' THEN
    RAISE EXCEPTION 'KITCHEN_DIRECT_COMPLETION_VERIFY_BULK_FLOW_INCORRECT';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.complete_kitchen_order(uuid,uuid)',
    'EXECUTE'
  ) OR has_function_privilege(
    'anon',
    'public.complete_kitchen_order(uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'KITCHEN_DIRECT_COMPLETION_VERIFY_GRANTS_INCORRECT';
  END IF;
END;
$verify$;
