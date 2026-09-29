\set ON_ERROR_STOP on
DO $$
BEGIN
  IF md5(pg_get_functiondef(
      'public.get_receipt_ledger(date,uuid,text,text,integer,integer)'::regprocedure
    )) <> '299178ee6e1a68ed07053fe6ea996ba5' THEN
    RAISE EXCEPTION 'LEDGER_NAME_BASE_DEFINITION_CHANGED';
  END IF;
END $$;
SELECT 'BUNSIK_RECEIPT_LEDGER_NAMES_PREFLIGHT_OK' AS result;
