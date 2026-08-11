DO $preflight$
DECLARE
  v_pgcrypto_schema text;
BEGIN
  SELECT n.nspname INTO v_pgcrypto_schema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
  WHERE e.extname = 'pgcrypto';

  IF v_pgcrypto_schema IS DISTINCT FROM 'extensions' THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_PGCRYPTO_SCHEMA_UNEXPECTED schema=%',
      COALESCE(v_pgcrypto_schema, '<missing>');
  END IF;

  IF to_regprocedure('public.issue_digital_receipt_link(uuid)') IS NULL
     OR to_regprocedure('public.get_public_receipt(text)') IS NULL
     OR to_regclass('public.digital_receipt_links') IS NULL
     OR to_regclass('public.digital_receipts') IS NULL THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_BASE_CONTRACT_MISSING';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.issue_digital_receipt_link(uuid)',
       'EXECUTE'
     ) OR NOT has_function_privilege(
       'service_role',
       'public.get_public_receipt(text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_BASE_PRIVILEGES_MISSING';
  END IF;
END;
$preflight$;
