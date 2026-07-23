DO $verify$
DECLARE
  v_signature regprocedure := to_regprocedure(
    'public.upsert_inventory_supplier(uuid,uuid,text,text,text,text,text,text,text,text,date,date,text,text)'
  );
  v_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'inventory_suppliers'
      AND column_name = 'bank_account_number'
      AND data_type = 'text'
  ) THEN
    RAISE EXCEPTION 'SUPPLIER_BANK_ACCOUNT_VERIFY_COLUMN_MISSING';
  END IF;

  IF v_signature IS NULL THEN
    RAISE EXCEPTION 'SUPPLIER_BANK_ACCOUNT_VERIFY_RPC_MISSING';
  END IF;

  IF to_regprocedure(
    'public.upsert_inventory_supplier(uuid,uuid,text,text,text,text,text,text,text,text,date,date,text)'
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'SUPPLIER_BANK_ACCOUNT_VERIFY_LEGACY_RPC_PRESENT';
  END IF;

  SELECT pg_get_functiondef(v_signature)
  INTO v_definition;

  IF v_definition NOT LIKE '%bank_account_number%'
     OR v_definition NOT LIKE '%p_bank_account_number%' THEN
    RAISE EXCEPTION 'SUPPLIER_BANK_ACCOUNT_VERIFY_RPC_INCOMPLETE';
  END IF;

  IF NOT has_function_privilege('authenticated', v_signature, 'EXECUTE')
     OR has_function_privilege('anon', v_signature, 'EXECUTE') THEN
    RAISE EXCEPTION 'SUPPLIER_BANK_ACCOUNT_VERIFY_GRANTS_INCOMPLETE';
  END IF;
END;
$verify$;
