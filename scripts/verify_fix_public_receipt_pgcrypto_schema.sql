DO $verify$
DECLARE
  v_issue_definition text;
  v_lookup_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.issue_digital_receipt_link(uuid)'::regprocedure
  ) INTO v_issue_definition;
  SELECT pg_get_functiondef(
    'public.get_public_receipt(text)'::regprocedure
  ) INTO v_lookup_definition;

  IF position(
       'extensions.gen_random_bytes(24)' IN v_issue_definition
     ) = 0 OR position(
       'extensions.digest(v_token, ''sha256'')' IN v_issue_definition
     ) = 0 OR position(
       'extensions.digest(p_token, ''sha256'')' IN v_lookup_definition
     ) = 0 THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_PGCRYPTO_NOT_SCHEMA_QUALIFIED';
  END IF;

  IF has_function_privilege(
       'anon', 'public.get_public_receipt(text)', 'EXECUTE'
     ) OR has_function_privilege(
       'authenticated', 'public.get_public_receipt(text)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'service_role', 'public.get_public_receipt(text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_LOOKUP_PRIVILEGE_BOUNDARY_FAILED';
  END IF;

  IF public.get_public_receipt(
       'HHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_MISSING_TOKEN_ACCEPTED';
  END IF;
END;
$verify$;

\ir test_pos_paperless_receipt_security_runtime.sql
