-- First operational store pilot; Photo and SAMPLE stores remain disabled.
INSERT INTO public.company_tax_lookup_settings(store_id,enabled)
 VALUES('8bc9eef5-dcd5-46b1-b931-23f77132322c',true);
DO $release_verify$
DECLARE old record;
BEGIN
 SELECT * INTO old FROM pos_release_anchors;
 IF old.payment IS DISTINCT FROM md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))
 OR old.financials IS DISTINCT FROM (SELECT md5(COALESCE(string_agg(to_jsonb(f)::text,'' ORDER BY f.request_id),'')) FROM public.direct_order_financials f)
 OR old.issued_receipts IS DISTINCT FROM (SELECT md5(COALESCE(string_agg(snapshot::text,'' ORDER BY id),'')) FROM public.digital_receipts)
 THEN RAISE EXCEPTION 'POS_RELEASE_FINANCIAL_HISTORY_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.company_tax_lookup_settings WHERE store_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND enabled)
 OR (SELECT count(*) FROM public.company_tax_lookup_slots)<>2
 OR has_function_privilege('anon','public.pos_receipt_ledger_batch(date,uuid,uuid[],boolean)','EXECUTE')
 OR has_function_privilege('authenticated','public.pos_claim_company_tax_lookup(uuid,uuid,uuid)','EXECUTE')
 OR to_regprocedure('public.direct_order_public_status_v10(uuid,text,uuid)') IS NULL
 OR to_regprocedure('public.direct_order_staff_detail_v6(uuid,uuid)') IS NULL
 THEN RAISE EXCEPTION 'POS_RELEASE_CONTRACT_DRIFT'; END IF;
END; $release_verify$;
NOTIFY pgrst,'reload schema';
COMMIT;
