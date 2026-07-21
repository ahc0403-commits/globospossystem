DO $verify$
DECLARE
  v_function regprocedure;
  v_definition text;
  v_security_definer boolean;
  v_config text[];
BEGIN
  IF to_regclass('public.red_invoice_intakes') IS NULL THEN
    RAISE EXCEPTION 'RED_INVOICE_TABLE_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname = 'red_invoice_intakes'
      AND relation.relrowsecurity
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'red_invoice_intakes'
      AND policyname = 'red_invoice_intakes_store_read'
      AND 'authenticated' = ANY(roles)
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_RLS_INVALID';
  END IF;

  IF has_table_privilege('anon', 'public.red_invoice_intakes', 'SELECT')
     OR has_table_privilege(
       'authenticated', 'public.red_invoice_intakes', 'INSERT'
     )
     OR has_table_privilege(
       'authenticated', 'public.red_invoice_intakes', 'UPDATE'
     )
     OR has_table_privilege(
       'authenticated', 'public.red_invoice_intakes', 'DELETE'
     ) THEN
    RAISE EXCEPTION 'RED_INVOICE_TABLE_PRIVILEGE_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'red-invoice-intake'
      AND name = 'red-invoice-intake'
      AND public = false
      AND file_size_limit = 5242880
      AND allowed_mime_types @> ARRAY[
        'image/jpeg', 'image/png', 'image/webp'
      ]::text[]
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'storage_red_invoice_intake_scoped'
      AND 'authenticated' = ANY(roles)
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_BUCKET_INVALID';
  END IF;

  FOREACH v_function IN ARRAY ARRAY[
    'public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)'::regprocedure,
    'public.attach_red_invoice_intake_evidence(uuid,text)'::regprocedure,
    'public.list_red_invoice_intakes(date)'::regprocedure,
    'public.get_red_invoice_daily_export(date)'::regprocedure,
    'public.mark_red_invoice_intakes_exported(uuid[],uuid)'::regprocedure
  ] LOOP
    SELECT proc.prosecdef, proc.proconfig, pg_get_functiondef(proc.oid)
    INTO v_security_definer, v_config, v_definition
    FROM pg_proc proc
    WHERE proc.oid = v_function;

    IF NOT v_security_definer
       OR NOT (
         'search_path=public, auth' = ANY(COALESCE(v_config, ARRAY[]::text[]))
       ) THEN
      RAISE EXCEPTION 'RED_INVOICE_FUNCTION_INVALID:%', v_function;
    END IF;

    IF NOT has_function_privilege(
         'authenticated', v_function, 'EXECUTE'
       )
       OR has_function_privilege('anon', v_function, 'EXECUTE')
       OR has_function_privilege('public', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'RED_INVOICE_PRIVILEGE_INVALID:%', v_function;
    END IF;
  END LOOP;

  SELECT pg_get_functiondef(
    'public.get_red_invoice_daily_export(date)'::regprocedure
  ) INTO v_definition;
  IF v_definition NOT LIKE '%restaurant_daily_sales_finalizations%'
     OR v_definition NOT LIKE '%status = ''ready''%'
     OR v_definition NOT LIKE '%RED_INVOICE_MISA_CONFIG_REQUIRED%' THEN
    RAISE EXCEPTION 'RED_INVOICE_EXPORT_GUARD_INVALID';
  END IF;

  SELECT pg_get_functiondef(
    'public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)'::regprocedure
  ) INTO v_definition;
  IF v_definition NOT LIKE '%array_agg(payment.id::text%'
     OR v_definition NOT LIKE '%RED_INVOICE_DISABLED_FOR_PHOTO_OBJET%'
     OR v_definition NOT LIKE '%dispatch_paused%'
     OR v_definition NOT LIKE '%RED_INVOICE_INTAKE_LOCKED%' THEN
    RAISE EXCEPTION 'RED_INVOICE_INTAKE_GUARD_INVALID';
  END IF;
END
$verify$;

SELECT 'RED_INVOICE_INTAKE_EXPORT_VERIFY_OK';
