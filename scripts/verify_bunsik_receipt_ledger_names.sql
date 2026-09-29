\set ON_ERROR_STOP on
DO $$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_receipt_ledger(date,uuid,text,text,integer,integer)'::regprocedure
  ) INTO definition;
  IF position('v_business_date BETWEEN DATE ''2026-08-08'' AND DATE ''2026-09-28''' IN definition)=0
    OR position('correction.name_ko' IN definition)=0
    OR position('correction.name_vi' IN definition)=0
    OR position('correction.name_en' IN definition)=0
    OR position('8bc9eef5-dcd5-46b1-b931-23f77132322c' IN definition)=0
    OR md5(definition)='299178ee6e1a68ed07053fe6ea996ba5' THEN
    RAISE EXCEPTION 'BUNSIK_RECEIPT_LEDGER_NAMES_VERIFY_FAILED';
  END IF;
END $$;
SELECT 'BUNSIK_RECEIPT_LEDGER_NAMES_VERIFY_OK' AS result;
