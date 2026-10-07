DO $$ DECLARE definition text; BEGIN
  IF to_regprocedure('public.direct_order_public_status_v4(uuid,text,uuid)') IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DETAIL_RPC_MISSING';
  END IF;
  definition:=pg_get_functiondef('public.direct_order_public_status_v4(uuid,text,uuid)'::regprocedure);
  IF strpos(definition,'public.direct_order_public_status_v3(')=0
    OR strpos(definition,'r.session_id = p_session_id')=0
    OR strpos(definition,'r.pii_purged_at IS NOT NULL')=0
    OR strpos(definition,'''customer_note'', r.customer_note')=0
    OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid='public.direct_order_public_status_v4(uuid,text,uuid)'::regprocedure
      AND prosecdef AND proconfig @> ARRAY['search_path=public, pg_catalog'])
    OR has_function_privilege('anon','public.direct_order_public_status_v4(uuid,text,uuid)','EXECUTE')
    OR has_function_privilege('authenticated','public.direct_order_public_status_v4(uuid,text,uuid)','EXECUTE')
    OR NOT has_function_privilege('service_role','public.direct_order_public_status_v4(uuid,text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DETAIL_RUNTIME_CONTRACT_FAILED';
  END IF;
END $$;
SELECT 'DIRECT_ORDER_DETAIL_RUNTIME=PASS';
