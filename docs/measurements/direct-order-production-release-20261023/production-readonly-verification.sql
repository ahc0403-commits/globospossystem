BEGIN READ ONLY;
SET LOCAL statement_timeout='10s';
DO $verify$
DECLARE definition text; expression text; accepted boolean;
BEGIN
 IF (SELECT count(*) FROM supabase_migrations.schema_migrations WHERE version IN('20261023120000','20261023121000'))<>2 THEN RAISE EXCEPTION 'RELEASE_MIGRATION_HISTORY_INCOMPLETE'; END IF;
 SELECT pg_get_constraintdef(oid),pg_get_expr(conbin,conrelid) INTO definition,expression
 FROM pg_constraint WHERE conrelid='public.direct_order_request_addresses'::regclass
 AND conname='direct_order_address_detail_valid';
 IF definition IS NULL OR definition NOT LIKE '%>= 0%' OR definition NOT LIKE '%<= 300%' THEN
  RAISE EXCEPTION 'OPTIONAL_ADDRESS_CONSTRAINT_MISSING';
 END IF;
 EXECUTE format('SELECT bool_and(COALESCE((%s),true)) FROM (VALUES (NULL::text),(''''),(''  ''),(''Floor 2''),(repeat(''x'',300))) AS v(detail_address)',expression) INTO accepted;
 IF accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'OPTIONAL_ADDRESS_VALID_INPUT_REJECTED'; END IF;
 EXECUTE format('SELECT NOT (%s) FROM (VALUES(repeat(''x'',301))) AS v(detail_address)',expression) INTO accepted;
 IF accepted IS DISTINCT FROM true THEN RAISE EXCEPTION 'OVERSIZE_DETAIL_ACCEPTED'; END IF;
 IF strpos(pg_get_functiondef('public.direct_order_public_submit(uuid,text,uuid,jsonb)'::regprocedure),'COALESCE(v_address->>''detail_address'', '''')')=0
 OR strpos(pg_get_functiondef('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)'::regprocedure),'COALESCE(v_address->>''detail_address'', '''')')=0
 OR strpos(pg_get_functiondef('public.enqueue_direct_delivery_driver_receipt(uuid,uuid,boolean)'::regprocedure),'OR NULLIF(btrim(v_address.detail_address), '''') IS NULL')>0
 OR strpos(pg_get_functiondef('public.guard_direct_delivery_driver_receipt_job()'::regprocedure),'OR NULLIF(btrim(NEW.payload->>''detail_address''), '''') IS NULL')>0 THEN
  RAISE EXCEPTION 'OPTIONAL_ADDRESS_FUNCTION_DRIFT';
 END IF;
 IF has_function_privilege('anon','public.direct_order_public_proof_v3(uuid,text,uuid,uuid,uuid,uuid,text,boolean)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_public_proof_v3(uuid,text,uuid,uuid,uuid,uuid,text,boolean)','EXECUTE')
 OR NOT has_function_privilege('service_role','public.direct_order_public_proof_v3(uuid,text,uuid,uuid,uuid,uuid,text,boolean)','EXECUTE') THEN
  RAISE EXCEPTION 'PROOF_V3_ACCESS_INVALID';
 END IF;
 IF has_function_privilege('anon','public.direct_order_public_updates(uuid,text,uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_public_updates(uuid,text,uuid)','EXECUTE')
 OR NOT has_function_privilege('service_role','public.direct_order_public_updates(uuid,text,uuid)','EXECUTE') THEN
  RAISE EXCEPTION 'UPDATES_ACCESS_INVALID';
 END IF;
 IF (SELECT count(*) FROM pg_trigger WHERE tgrelid='public.direct_order_messages'::regclass AND tgenabled='O'
 AND tgname IN('direct_order_chat_revision_insert','direct_order_chat_revision_update','direct_order_chat_revision_delete'))<>3 THEN
  RAISE EXCEPTION 'CHAT_REVISION_TRIGGERS_INVALID';
 END IF;
 IF strpos(pg_get_functiondef('public.direct_order_capture_requirements()'::regprocedure),'''cashier'' FROM')=0
 OR strpos(pg_get_functiondef('public.direct_order_capture_requirements()'::regprocedure),'''preparation''')=0
 OR strpos(pg_get_functiondef('public.direct_order_requirement_print_snapshot(uuid,text)'::regprocedure),'print_scope<>''cashier''')=0
 OR strpos(pg_get_functiondef('public.direct_order_emit_requirement_addendum(uuid)'::regprocedure),'q.print_scope=''cashier''')=0 THEN
  RAISE EXCEPTION 'NOTE_AUDIENCE_FUNCTION_DRIFT';
 END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_customer_requirements WHERE source_kind='order' AND print_scope='both') THEN
  RAISE EXCEPTION 'LEGACY_ORDER_BOTH_NOTE_REMAINS';
 END IF;
END;
$verify$;
SELECT 'PASS' AS production_schema_contract,
 (SELECT count(*) FROM supabase_migrations.schema_migrations WHERE version IN('20261023120000','20261023121000')) AS applied_release_migrations,
 (SELECT count(*) FROM public.direct_order_customer_requirements WHERE source_kind='order' AND print_scope='cashier') AS private_order_notes,
 (SELECT count(*) FROM public.direct_order_customer_requirements WHERE source_kind='item' AND print_scope IN('preparation','both')) AS preparation_item_notes;
WITH target AS MATERIALIZED (
 SELECT id,request_id FROM public.direct_order_customer_requirements
 WHERE source_kind='order' AND print_scope='cashier' AND status='confirmed'
 AND restaurant_id=(SELECT restaurant_id FROM public.direct_order_storefronts WHERE public_slug='bunsikclub-binh-thanh')
 ORDER BY created_at DESC,id DESC LIMIT 1
), snapshots AS MATERIALIZED (
 SELECT t.id,public.direct_order_requirement_snapshot(t.request_id) AS admin_notes,
 public.direct_order_requirement_print_snapshot(t.request_id,scope)->'confirmed_requirements' AS printed
 FROM target t CROSS JOIN unnest(ARRAY['preparation','delivery','receipt']) AS scope
)
SELECT 'PASS' AS production_schema_contract,
 (SELECT count(*) FROM supabase_migrations.schema_migrations WHERE version IN('20261023120000','20261023121000')) AS applied_release_migrations,
 (SELECT count(*) FROM public.direct_order_customer_requirements WHERE source_kind='order' AND print_scope='cashier') AS private_order_notes,
 (SELECT count(*) FROM public.direct_order_customer_requirements WHERE source_kind='item' AND print_scope IN('preparation','both')) AS preparation_item_notes,
 (SELECT count(*) FROM target) AS confirmed_private_orders_checked,
 bool_and(EXISTS(SELECT 1 FROM jsonb_array_elements(admin_notes) AS n WHERE n->>'id'=snapshots.id::text)) AS admin_keeps_private_note,
 bool_and(NOT EXISTS(SELECT 1 FROM jsonb_array_elements(printed) AS n WHERE n->>'id'=snapshots.id::text)) AS preparation_delivery_receipt_hide_private_note
FROM snapshots;
COMMIT;
