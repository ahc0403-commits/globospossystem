DO $$ BEGIN
 IF to_regclass('public.pos_live_events') IS NULL
 OR position('approval_policy_version' IN pg_get_functiondef('public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure))=0
 OR to_regprocedure('public.procurement_pre_inbox_command(uuid,text,uuid,integer,text,jsonb,jsonb)') IS NOT NULL
 OR has_function_privilege('authenticated','public.procurement_actor(uuid,jsonb)','EXECUTE')
 THEN RAISE EXCEPTION 'PROCUREMENT_INBOX_PRECONDITION_FAILED'; END IF;
END $$;
