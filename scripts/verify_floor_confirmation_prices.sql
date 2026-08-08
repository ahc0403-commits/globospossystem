DO $verify$
DECLARE
  v_function regprocedure := to_regprocedure(
    'public.enqueue_print_jobs(uuid,text[],jsonb,text)'
  );
  v_definition text;
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'FLOOR_CONFIRMATION_PRICE_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_function)
  INTO v_definition;

  IF position('order_item.unit_price' IN v_definition) = 0
     OR position('menu_item.price' IN v_definition) = 0
     OR position('v_full_items' IN v_definition) = 0
     OR position('order_item.status <> ''cancelled''' IN v_definition) = 0
     OR position('v_copy_type IN (''floor'', ''confirmation'')' IN v_definition) = 0
     OR position('ELSE v_items' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FLOOR_CONFIRMATION_PRICE_CONTRACT_MISSING';
  END IF;

  IF has_function_privilege('anon', v_function, 'EXECUTE')
     OR has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'FLOOR_CONFIRMATION_PRICE_EXECUTE_EXPOSED';
  END IF;
END;
$verify$;
