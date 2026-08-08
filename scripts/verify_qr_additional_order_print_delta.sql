\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_function regprocedure := to_regprocedure(
    'public.qr_place_order(text,jsonb,uuid)'
  );
  v_definition text;
  v_security_definer boolean;
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'QR_PRINT_DELTA_VERIFY_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_function), prosecdef
  INTO v_definition, v_security_definer
  FROM pg_proc
  WHERE oid = v_function;

  IF NOT v_security_definer THEN
    RAISE EXCEPTION 'QR_PRINT_DELTA_VERIFY_SECURITY_CHANGED';
  END IF;

  IF position('RETURNING * INTO v_inserted_item' IN v_definition) = 0
     OR position('''item_id'', v_inserted_item.id::text' IN v_definition) = 0
     OR position('v_print_items' IN v_definition) = 0
     OR position('ARRAY[''kitchen'', ''floor'', ''confirmation'']' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'QR_PRINT_DELTA_VERIFY_CONTRACT_MISSING';
  END IF;
END;
$verify$;
