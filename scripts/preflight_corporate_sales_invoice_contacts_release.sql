-- Read-only prerequisites; emits no customer values or credentials.
DO $preflight$
DECLARE definitions jsonb; eligible integer;
BEGIN
 SELECT jsonb_object_agg(signature,pg_get_functiondef(to_regprocedure(signature))) INTO definitions FROM (VALUES
 ('public.direct_order_public_resume_storefront(uuid,text)'),
 ('public.direct_order_admin_get_storefront(uuid)'),
 ('public.get_restaurant_daily_sales_exports_by_tax_entity(date)'),
 ('public.enqueue_meinvoice_cash_register_job()'),
 ('public.claim_meinvoice_jobs(uuid,integer,uuid)')) required(signature);
 IF EXISTS(SELECT 1 FROM jsonb_each(definitions) d WHERE d.value='null'::jsonb) THEN RAISE EXCEPTION 'CORPORATE_RELEASE_PREREQUISITE_MISSING'; END IF;
 IF strpos(definitions->>'public.direct_order_admin_get_storefront(uuid)', '''accounting_approved'', v_row.accounting_approved_at IS NOT NULL')=0
 OR strpos(definitions->>'public.direct_order_public_resume_storefront(uuid,text)', 'RETURN v_result;')=0
 OR strpos(definitions->>'public.get_restaurant_daily_sales_exports_by_tax_entity(date)', 'public.pos_restaurant_receipt_rows(')=0
 OR strpos(definitions->>'public.enqueue_meinvoice_cash_register_job()', '''item_type'', oi.item_type,')=0
 OR strpos(definitions->>'public.enqueue_meinvoice_cash_register_job()', '  WHERE oi.order_id = NEW.id')=0
 OR strpos(definitions->>'public.claim_meinvoice_jobs(uuid,integer,uuid)', 'status=''pending'' AND dispatch_claim_id IS NULL')=0 THEN RAISE EXCEPTION 'CORPORATE_RELEASE_ANCHOR_CHANGED'; END IF;
 IF to_regclass('public.tax_entity_collection_accounts') IS NOT NULL OR to_regclass('public.menu_invoice_profiles') IS NOT NULL
 OR to_regclass('public.meinvoice_job_snapshot_versions') IS NOT NULL
 OR EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND
 ((table_name='direct_order_sessions' AND column_name='collection_bank_snapshot') OR (table_name='meinvoice_jobs' AND column_name='snapshot_version')
 OR (table_name='menu_items' AND column_name IN('invoice_name_vi','invoice_unit_name')))) THEN RAISE EXCEPTION 'CORPORATE_RELEASE_ALREADY_PARTIALLY_APPLIED'; END IF;
 SELECT count(*) INTO eligible FROM public.tax_entity WHERE id='a6bda671-4179-5a29-a798-76357b42b497'::uuid
 OR upper(regexp_replace(name,'[^A-Za-z]','','g'))='AKJINTERNATIONALCOLTD';
 IF eligible<>1 THEN RAISE EXCEPTION 'CORPORATE_RELEASE_AKJ_ENTITY_AMBIGUOUS'; END IF;
 RAISE NOTICE 'CORPORATE_RELEASE_PREFLIGHT=PASS';
END $preflight$;
