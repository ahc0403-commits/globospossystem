-- Read-only production postconditions for idempotent document registration.
BEGIN TRANSACTION READ ONLY;
DO $verify$
DECLARE target regprocedure := 'public.record_procurement_document(uuid,text,uuid,text,text,text,text,integer,jsonb)'::regprocedure;
        definition text;
BEGIN
  SELECT pg_get_functiondef(target) INTO definition;
  IF position('FOR UPDATE' IN definition) = 0
     OR position('PROCUREMENT_DOCUMENT_SOURCE_CHANGED' IN definition) = 0
     OR position('PROCUREMENT_DOCUMENT_FILE_REQUIRED' IN definition) = 0
     OR position('existing.status=''ready''' IN definition) = 0
     OR position('''replayed'',true' IN definition) = 0
     OR position('''document_generated''' IN definition) = 0
     OR position('''replayed'',true' IN definition) > position('''document_generated''' IN definition) THEN
    RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_RETRY_CONTRACT_MISSING';
  END IF;
  IF has_function_privilege('anon', target, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', target, 'EXECUTE')
     OR NOT has_function_privilege('service_role', target, 'EXECUTE') THEN
    RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_RETRY_PRIVILEGES_INVALID';
  END IF;
END $verify$;
ROLLBACK;
