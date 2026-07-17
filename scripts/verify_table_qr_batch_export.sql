DO $$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
       'public.admin_get_or_create_table_qrs(uuid,uuid[])'
     ) IS NULL THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_VERIFY_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.admin_get_or_create_table_qrs(uuid,uuid[])'::regprocedure
  ) INTO v_definition;

  IF v_definition NOT LIKE '%public.require_admin_actor_for_restaurant%'
     OR v_definition NOT LIKE '%ON CONFLICT (table_id) WHERE is_active DO NOTHING%'
     OR v_definition NOT LIKE '%ORDER BY t.layout_sort_order, t.table_number, t.id%'
     OR v_definition LIKE '%UPDATE public.table_qr_tokens%'
     OR v_definition NOT LIKE '%extensions.gen_random_bytes(24)%' THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_VERIFY_RPC_CONTRACT_INVALID';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.admin_get_or_create_table_qrs(uuid,uuid[])',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.admin_get_or_create_table_qrs(uuid,uuid[])',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_VERIFY_RPC_GRANT_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.table_qr_tokens
    WHERE is_active = true
    GROUP BY table_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'TABLE_QR_BATCH_VERIFY_DUPLICATE_ACTIVE_TOKEN';
  END IF;
END;
$$;

SELECT 'TABLE_QR_BATCH_VERIFY_OK' AS result;
