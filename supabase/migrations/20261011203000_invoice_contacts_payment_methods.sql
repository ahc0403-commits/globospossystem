BEGIN;
-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
-- Preserve method identity: VNPAY has no recorded funding route, Voucher is
-- recorded tender (not a new discount), and Credit Sale remains unpaid tender.
CREATE OR REPLACE FUNCTION public.misa_payment_code_for_methods(p_methods text[]) RETURNS text
 LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 WITH methods AS(SELECT DISTINCT upper(btrim(value)) method FROM unnest(p_methods) value),
 labels AS(SELECT DISTINCT CASE method WHEN 'CASH' THEN 'TM' WHEN 'BANKTRANSFER' THEN 'CK'
 WHEN 'CREDITCARD' THEN 'Thẻ quốc tế' WHEN 'ATM' THEN 'Thẻ ATM' WHEN 'VNPAY' THEN 'VNPAY'
 WHEN 'VOUCHER' THEN 'Voucher' WHEN 'CREDITSALE' THEN 'Chưa thu tiền' ELSE 'Ví điện tử' END label FROM methods)
 SELECT CASE WHEN count(*)=0 OR bool_or(method IS NULL OR method NOT IN('CASH','BANKTRANSFER','CREDITCARD','ATM','MOMO','ZALOPAY','SHOPEEPAY','VNPAY','VOUCHER','CREDITSALE','OTHER','EPAY','PAY')) THEN 'UNMAPPED'
 WHEN count(*)=2 AND bool_and(method IN('CASH','BANKTRANSFER')) THEN 'TM/CK'
 ELSE (SELECT string_agg(label,'/' ORDER BY label COLLATE "C") FROM labels) END FROM methods;
$$;
CREATE FUNCTION public.misa_payment_kind_for_methods(p_methods text[]) RETURNS text
 LANGUAGE sql IMMUTABLE SET search_path=public,pg_catalog AS $$
 WITH methods AS(SELECT DISTINCT upper(btrim(value)) method FROM unnest(p_methods) value)
 SELECT CASE WHEN public.misa_payment_code_for_methods(p_methods)='UNMAPPED' THEN 'UNMAPPED'
 WHEN count(*)>1 THEN 'MIXED' ELSE max(CASE method WHEN 'CREDITCARD' THEN 'CARD' WHEN 'ATM' THEN 'CARD'
 WHEN 'MOMO' THEN 'EWALLET' WHEN 'ZALOPAY' THEN 'EWALLET' WHEN 'SHOPEEPAY' THEN 'EWALLET'
 WHEN 'OTHER' THEN 'EWALLET' WHEN 'EPAY' THEN 'EWALLET' WHEN 'PAY' THEN 'EWALLET' WHEN 'VNPAY' THEN 'GATEWAY' ELSE method END) END FROM methods;
$$;
REVOKE ALL ON FUNCTION public.misa_payment_kind_for_methods(text[]) FROM PUBLIC,anon,authenticated;

-- Pure contact selection; no queries, extra RPCs, or inferred customer data.
CREATE FUNCTION public.misa_buyer_contact_snapshot(p_intake_id uuid,p_email text,p_phone text,p_snapshot jsonb,p_locked boolean) RETURNS jsonb
 LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT jsonb_build_object('email',btrim(COALESCE(CASE WHEN p_locked THEN p_snapshot->>'email'
 WHEN p_intake_id IS NOT NULL THEN p_email ELSE p_snapshot->>'email' END,'')),
 'phone',btrim(COALESCE(CASE WHEN p_locked THEN p_snapshot->>'phone'
 WHEN p_intake_id IS NOT NULL THEN p_phone ELSE p_snapshot->>'phone' END,'')));
$$;
REVOKE ALL ON FUNCTION public.misa_buyer_contact_snapshot(uuid,text,text,jsonb,boolean) FROM PUBLIC,anon,authenticated;

-- Previous archives have no recoverable buyer snapshot; leave those NULL.
ALTER TABLE public.meinvoice_job_snapshot_versions ADD COLUMN buyer_snapshot jsonb;
CREATE OR REPLACE FUNCTION public.preserve_meinvoice_export_snapshot() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF OLD.payment_method_snapshot IS NOT DISTINCT FROM NEW.payment_method_snapshot AND OLD.line_items_snapshot IS NOT DISTINCT FROM NEW.line_items_snapshot
 AND OLD.payment_summary IS NOT DISTINCT FROM NEW.payment_summary AND OLD.buyer_snapshot IS NOT DISTINCT FROM NEW.buyer_snapshot THEN RETURN NEW; END IF;
 IF OLD.status IN('sent_to_misa','sent_to_tax_authority','valid_invoice','resolved') OR OLD.misa_ref_id IS NOT NULL OR OLD.invoice_number IS NOT NULL OR OLD.dispatch_claim_id IS NOT NULL OR COALESCE(OLD.dispatch_attempts,0)>0 THEN RAISE EXCEPTION 'MEINVOICE_ISSUED_SNAPSHOT_IMMUTABLE'; END IF;
 INSERT INTO public.meinvoice_job_snapshot_versions(job_id,snapshot_version,payment_method_snapshot,line_items_snapshot,payment_summary,buyer_snapshot,source_hash)
 VALUES(OLD.id,OLD.snapshot_version,OLD.payment_method_snapshot,OLD.line_items_snapshot,OLD.payment_summary,OLD.buyer_snapshot,
 md5(jsonb_build_object('method',OLD.payment_method_snapshot,'items',OLD.line_items_snapshot,'payments',OLD.payment_summary,'buyer',OLD.buyer_snapshot)::text)) ON CONFLICT DO NOTHING;
 NEW.snapshot_version:=OLD.snapshot_version+1; RETURN NEW;
END $$;

DO $receipt$ DECLARE d text; anchor text; BEGIN
 SELECT pg_get_functiondef('public.pos_restaurant_receipt_rows_v2(date,uuid[])'::regprocedure) INTO d;
 anchor:='candidate.line_items_snapshot,candidate.snapshot_version';
 IF strpos(d,anchor)=0 OR strpos(d,'COALESCE(intake.buyer_email, '''') AS buyer_email')=0
 OR strpos(d,'COALESCE(intake.buyer_phone, '''') AS buyer_phone')=0
 OR strpos(d,'LEFT JOIN order_lines ON order_lines.order_id=paid.order_id')=0
 OR strpos(d,'''methods'',paid.payment_methods,')=0
 OR strpos(d,$old$CASE WHEN cardinality(paid.payment_methods)>1 THEN 'MIXED' WHEN upper(paid.payment_methods[1]) IN('CREDITCARD','ATM') THEN 'CARD' WHEN upper(paid.payment_methods[1]) IN('EPAY','PAY','OTHER') THEN 'EWALLET' ELSE upper(paid.payment_methods[1]) END AS payment_code$old$)=0
 THEN RAISE EXCEPTION 'INVOICE_CONTACT_EXPORT_ANCHOR_CHANGED'; END IF;
 d:=replace(d,anchor,anchor||',candidate.buyer_snapshot,(candidate.status IN(''sent_to_misa'',''sent_to_tax_authority'',''valid_invoice'',''resolved'') OR candidate.misa_ref_id IS NOT NULL OR candidate.invoice_number IS NOT NULL OR candidate.dispatch_claim_id IS NOT NULL OR COALESCE(candidate.dispatch_attempts,0)>0) contact_locked');
 d:=replace(d,'COALESCE(intake.buyer_email, '''') AS buyer_email','contacts.buyer->>''email'' AS buyer_email');
 d:=replace(d,'COALESCE(intake.buyer_phone, '''') AS buyer_phone','contacts.buyer->>''phone'' AS buyer_phone');
 d:=replace(d,'LEFT JOIN order_lines ON order_lines.order_id=paid.order_id',
 'LEFT JOIN order_lines ON order_lines.order_id=paid.order_id CROSS JOIN LATERAL (SELECT public.misa_buyer_contact_snapshot(intake.id,intake.buyer_email,intake.buyer_phone,job.buyer_snapshot,COALESCE(job.contact_locked,false)) buyer) contacts');
 d:=replace(d,'''methods'',paid.payment_methods,','''methods'',paid.payment_methods,''buyer_contacts'',contacts.buyer,');
 d:=replace(d,$old$CASE WHEN cardinality(paid.payment_methods)>1 THEN 'MIXED' WHEN upper(paid.payment_methods[1]) IN('CREDITCARD','ATM') THEN 'CARD' WHEN upper(paid.payment_methods[1]) IN('EPAY','PAY','OTHER') THEN 'EWALLET' ELSE upper(paid.payment_methods[1]) END AS payment_code$old$,
 'public.misa_payment_kind_for_methods(paid.payment_methods) AS payment_code');
 IF strpos(d,'contacts.buyer->>''email'' AS buyer_email')=0 OR strpos(d,'contacts.buyer->>''phone'' AS buyer_phone')=0
 OR strpos(d,'''buyer_contacts'',contacts.buyer,')=0
 OR strpos(d,'public.misa_payment_kind_for_methods(paid.payment_methods) AS payment_code')=0
 THEN RAISE EXCEPTION 'INVOICE_CONTACT_EXPORT_PATCH_INCOMPLETE'; END IF;
 EXECUTE d;
END $receipt$;

CREATE OR REPLACE FUNCTION public.refresh_meinvoice_export_snapshots(p_business_date date,p_tax_entity_id uuid,p_order_ids uuid[]) RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE n integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF p_business_date IS NULL OR p_business_date<DATE '2020-01-01' OR p_business_date>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR p_tax_entity_id IS NULL
 OR cardinality(p_order_ids) NOT BETWEEN 1 AND 100 OR p_order_ids IS NULL OR EXISTS(SELECT 1 FROM unnest(p_order_ids) x WHERE x IS NULL)
 OR cardinality(p_order_ids)<>(SELECT count(DISTINCT x) FROM unnest(p_order_ids) x) THEN RAISE EXCEPTION 'INVOICE_EXPORT_SCOPE_INVALID'; END IF;
 WITH scope AS MATERIALIZED(SELECT * FROM public.pos_restaurant_receipt_rows_v2(p_business_date,p_order_ids))
 SELECT count(*) INTO n FROM scope WHERE tax_entity_id=p_tax_entity_id;
 IF n<>cardinality(p_order_ids) THEN RAISE EXCEPTION 'INVOICE_EXPORT_SCOPE_CHANGED'; END IF;
 WITH scope AS MATERIALIZED(SELECT * FROM public.pos_restaurant_receipt_rows_v2(p_business_date,p_order_ids) r WHERE r.tax_entity_id=p_tax_entity_id),
 updates AS(SELECT j.id,s.payment_method,s.line_items,
 j.buyer_snapshot||jsonb_build_object('email',s.buyer_email,'phone',s.buyer_phone) buyer,
 j.payment_summary||jsonb_build_object('methods',to_jsonb(s.payment_methods)) payments FROM public.meinvoice_jobs j JOIN scope s ON j.order_id::text=s.receipt_id
 WHERE j.tax_entity_id=p_tax_entity_id AND j.status IN('pending_manual_config','dispatch_paused','pending')
 AND j.dispatch_claim_id IS NULL AND j.misa_ref_id IS NULL AND j.invoice_number IS NULL AND COALESCE(j.dispatch_attempts,0)=0
 AND s.payment_method<>'UNMAPPED' AND jsonb_array_length(s.line_items)>0
 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(s.line_items) line WHERE COALESCE(line->>'invoice_name_vi','')='' OR COALESCE(line->>'misa_unit_name','')='')),
 updated AS(UPDATE public.meinvoice_jobs j SET payment_method_snapshot=u.payment_method,line_items_snapshot=u.line_items,buyer_snapshot=u.buyer,payment_summary=u.payments,updated_at=now()
 FROM updates u WHERE j.id=u.id AND ROW(j.payment_method_snapshot,j.line_items_snapshot,j.buyer_snapshot,j.payment_summary) IS DISTINCT FROM ROW(u.payment_method,u.line_items,u.buyer,u.payments) RETURNING j.id)
 SELECT count(*) INTO n FROM updated;
 RETURN n;
END $$;
REVOKE ALL ON FUNCTION public.refresh_meinvoice_export_snapshots(date,uuid,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.refresh_meinvoice_export_snapshots(date,uuid,uuid[]) TO authenticated;
DO $verify$ BEGIN
 IF public.misa_payment_code_for_methods(ARRAY['MOMO'])<>'Ví điện tử' OR public.misa_payment_code_for_methods(ARRAY['VNPAY'])<>'VNPAY'
 OR public.misa_payment_kind_for_methods(ARRAY['VOUCHER'])<>'VOUCHER' OR public.misa_payment_kind_for_methods(ARRAY['CREDITSALE'])<>'CREDITSALE'
 OR public.misa_payment_code_for_methods(ARRAY['BANKTRANSFER'])<>'CK' OR public.misa_payment_code_for_methods(ARRAY['QR'])<>'UNMAPPED'
 OR has_function_privilege('anon','public.refresh_meinvoice_export_snapshots(date,uuid,uuid[])','EXECUTE') THEN RAISE EXCEPTION 'INVOICE_CONTACT_PAYMENT_CONTRACT_DRIFT'; END IF;
END $verify$;
COMMIT;
