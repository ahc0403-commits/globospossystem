DO $verify$
DECLARE
  v_function regprocedure := to_regprocedure(
    'public.get_sepay_payment_alerts_after(uuid,timestamptz,bigint,integer)'
  );
  v_definition text;
  v_security_definer boolean;
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'SEPAY_ORDERED_ALERTS_VERIFY_FAILED: function missing';
  END IF;

  SELECT procedure_row.prosecdef, pg_get_functiondef(procedure_row.oid)
  INTO v_security_definer, v_definition
  FROM pg_proc procedure_row
  WHERE procedure_row.oid = v_function;

  IF NOT v_security_definer
     OR position('auth.uid() IS NULL' IN v_definition) = 0
     OR position('user_accessible_stores(auth.uid())' IN v_definition) = 0
     OR position('txn.restaurant_id = p_store_id' IN v_definition) = 0
     OR position('txn.transfer_type = ''in''' IN v_definition) = 0
     OR position('txn.resolution_status = ''matched''' IN v_definition) = 0
     OR position(
       'ORDER BY txn.received_at ASC, txn.sepay_transaction_id ASC'
       IN v_definition
     ) = 0 THEN
    RAISE EXCEPTION 'SEPAY_ORDERED_ALERTS_VERIFY_FAILED: contract mismatch';
  END IF;

  IF NOT has_function_privilege('authenticated', v_function, 'EXECUTE')
     OR has_function_privilege('anon', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'SEPAY_ORDERED_ALERTS_VERIFY_FAILED: grants mismatch';
  END IF;
END;
$verify$;
