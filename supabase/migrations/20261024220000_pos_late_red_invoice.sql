-- Late VAT requests reuse the paid order; they never issue a second invoice.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';

-- Change effective definitions, preserving subsequent fixes and privileges.
DO $phone$
DECLARE sig text; d text; next_d text;
BEGIN
 FOREACH sig IN ARRAY ARRAY[
  'public.pos_save_buyer_information(uuid,uuid,bigint,jsonb,boolean,text,text)',
  'public.pos_sync_direct_buyer_information(uuid,uuid,uuid[])',
  'public.pos_direct_order_save_buyer(uuid,uuid,integer,jsonb)',
  'public.upsert_red_invoice_intake_minimal(uuid,uuid,text,text,text,text,text,text,text,text)',
  'public.direct_order_sync_invoice_before_pos_buyer(uuid,uuid,uuid[])'
 ] LOOP
  SELECT pg_get_functiondef(sig::regprocedure) INTO d;
  next_d:=replace(d,' OR COALESCE(btrim(data->>''buyer_phone''),'''')=''''','');
  next_d:=replace(next_d,' OR COALESCE($4->>''buyer_phone'','''')=''''','');
  next_d:=replace(next_d,' AND COALESCE(b->>''phone'','''')<>''''','');
  next_d:=replace(next_d,' AND COALESCE(btrim(buyer->>''phone''),'''')<>''''','');
  next_d:=regexp_replace(next_d,'\s+OR COALESCE\(btrim\(p_buyer_phone\), ''''\) = ''''','','g');
  IF next_d=d THEN RAISE EXCEPTION 'LATE_INVOICE_PHONE_ANCHOR_CHANGED: %',sig; END IF;
  EXECUTE next_d;
 END LOOP;
END $phone$;

-- Preserve the same immutable-snapshot contract without a lookup/archive INSERT
-- per order in a combined request. The row guard is pure; the transition-table
-- guard checks external reporting and archives the complete changed set once.
CREATE OR REPLACE FUNCTION public.preserve_meinvoice_export_snapshot() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF ROW(OLD.payment_method_snapshot,OLD.line_items_snapshot,OLD.payment_summary,OLD.buyer_snapshot)
  IS NOT DISTINCT FROM ROW(NEW.payment_method_snapshot,NEW.line_items_snapshot,NEW.payment_summary,NEW.buyer_snapshot) THEN RETURN NEW; END IF;
 IF OLD.status IN('sent_to_misa','sent_to_tax_authority','valid_invoice','resolved') OR OLD.misa_ref_id IS NOT NULL
  OR OLD.invoice_number IS NOT NULL OR OLD.dispatch_claim_id IS NOT NULL OR coalesce(OLD.dispatch_attempts,0)>0
 THEN RAISE EXCEPTION 'MEINVOICE_ISSUED_SNAPSHOT_IMMUTABLE'; END IF;
 NEW.snapshot_version:=OLD.snapshot_version+1;
 RETURN NEW;
END $$;
CREATE FUNCTION public.capture_meinvoice_export_snapshots_batch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM invoice_old_versions o JOIN invoice_new_versions n USING(id)
  WHERE ROW(o.payment_method_snapshot,o.line_items_snapshot,o.payment_summary,o.buyer_snapshot)
   IS DISTINCT FROM ROW(n.payment_method_snapshot,n.line_items_snapshot,n.payment_summary,n.buyer_snapshot)) THEN RETURN NULL; END IF;
 IF EXISTS(
  WITH changed AS MATERIALIZED(
   SELECT o.* FROM invoice_old_versions o JOIN invoice_new_versions n USING(id)
   WHERE ROW(o.payment_method_snapshot,o.line_items_snapshot,o.payment_summary,o.buyer_snapshot)
    IS DISTINCT FROM ROW(n.payment_method_snapshot,n.line_items_snapshot,n.payment_summary,n.buyer_snapshot)
  ), paid AS MATERIALIZED(
   SELECT p.order_id,(max(p.created_at) AT TIME ZONE 'Asia/Ho_Chi_Minh')::date day_value
   FROM payments p JOIN changed c ON c.order_id=p.order_id AND c.source_system='restaurant_pos'
   WHERE p.is_revenue GROUP BY p.order_id
  ) SELECT 1 FROM changed c LEFT JOIN paid p ON p.order_id=c.order_id
   JOIN sales_external_reporting_protections x ON x.tax_entity_id=c.tax_entity_id AND x.source_system=c.source_system
   AND x.business_date=CASE WHEN c.source_system='restaurant_pos' THEN p.day_value
    ELSE (nullif(c.source_snapshot->>'sale_date','')::timestamptz AT TIME ZONE 'Asia/Ho_Chi_Minh')::date END
 ) THEN RAISE EXCEPTION 'MEINVOICE_EXTERNALLY_REPORTED_IMMUTABLE'; END IF;
 INSERT INTO meinvoice_job_snapshot_versions(job_id,snapshot_version,payment_method_snapshot,line_items_snapshot,payment_summary,buyer_snapshot,source_hash)
 SELECT o.id,o.snapshot_version,o.payment_method_snapshot,o.line_items_snapshot,o.payment_summary,o.buyer_snapshot,
  md5(jsonb_build_object('method',o.payment_method_snapshot,'items',o.line_items_snapshot,'payments',o.payment_summary,'buyer',o.buyer_snapshot)::text)
 FROM invoice_old_versions o JOIN invoice_new_versions n USING(id)
 WHERE ROW(o.payment_method_snapshot,o.line_items_snapshot,o.payment_summary,o.buyer_snapshot)
  IS DISTINCT FROM ROW(n.payment_method_snapshot,n.line_items_snapshot,n.payment_summary,n.buyer_snapshot)
 ON CONFLICT DO NOTHING;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.capture_meinvoice_export_snapshots_batch() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER capture_meinvoice_export_snapshots_batch AFTER UPDATE ON public.meinvoice_jobs
REFERENCING OLD TABLE AS invoice_old_versions NEW TABLE AS invoice_new_versions
FOR EACH STATEMENT EXECUTE FUNCTION public.capture_meinvoice_export_snapshots_batch();

CREATE TABLE public.pos_late_invoice_requests(
 id uuid PRIMARY KEY,
 actor_id uuid NOT NULL REFERENCES auth.users(id),
 store_id uuid NOT NULL REFERENCES public.restaurants(id),
 payload jsonb NOT NULL,
 result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.pos_late_invoice_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pos_late_invoice_requests FROM PUBLIC,anon,authenticated,service_role;

-- Private set-based resolution. An order in a combined payment, or a direct
-- request with several paid charges, cannot be edited partially.
CREATE FUNCTION public.pos_late_invoice_targets(p_store uuid,p_order uuid,p_group uuid)
RETURNS SETOF uuid LANGUAGE sql STABLE SET search_path=public,pg_catalog AS $$
 WITH groups AS MATERIALIZED(
  SELECT p_group id WHERE p_group IS NOT NULL
  UNION SELECT p.combined_payment_group_id FROM payments p
   WHERE p.order_id=p_order AND p.restaurant_id=p_store AND p.is_revenue AND p.combined_payment_group_id IS NOT NULL
 ), seed AS MATERIALIZED(
  SELECT p_order id WHERE p_order IS NOT NULL
  UNION SELECT p.order_id FROM payments p JOIN groups g ON g.id=p.combined_payment_group_id
   WHERE p.is_revenue
 ), requests AS MATERIALIZED(
  SELECT f.request_id FROM direct_order_financials f JOIN seed s ON s.id=f.order_id WHERE f.restaurant_id=p_store
  UNION SELECT c.request_id FROM direct_order_payment_charges c JOIN seed s ON s.id=c.order_id WHERE c.restaurant_id=p_store
 )
 SELECT id FROM seed
 UNION SELECT f.order_id FROM direct_order_financials f JOIN requests r ON r.request_id=f.request_id
 UNION SELECT c.order_id FROM direct_order_payment_charges c JOIN requests r ON r.request_id=c.request_id WHERE c.order_id IS NOT NULL;
$$;
REVOKE ALL ON FUNCTION public.pos_late_invoice_targets(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.pos_late_invoice_order_states(p_ids uuid[])
RETURNS TABLE(order_id uuid,store_id uuid,state text,editable boolean,buyer_version bigint,buyer jsonb,gross numeric,sold_at timestamptz)
LANGUAGE sql STABLE SET search_path=public,pg_catalog AS $$
 WITH paid AS MATERIALIZED(
  SELECT p.order_id,sum(coalesce(p.amount_portion,p.amount)) gross,max(p.created_at) sold_at,
   bool_or(p.restaurant_id IS DISTINCT FROM o.restaurant_id) wrong_store
  FROM payments p JOIN orders o ON o.id=p.order_id WHERE p.order_id=ANY(p_ids) AND p.is_revenue GROUP BY p.order_id
 ), adjustments AS MATERIALIZED(
  SELECT p.order_id,sum(a.amount) amount FROM payment_adjustments a JOIN payments p ON p.id=a.payment_id
  WHERE p.order_id=ANY(p_ids) GROUP BY p.order_id
 ), event_flags AS MATERIALIZED(
  SELECT j.order_id,bool_or((e.event_type LIKE 'dispatch_%' AND e.event_type<>'dispatch_deferred') OR coalesce(e.retry_count,0)>0) attempted
  FROM meinvoice_jobs j JOIN meinvoice_job_events e ON e.job_id=j.id WHERE j.order_id=ANY(p_ids) GROUP BY j.order_id
 ), legacy_flags AS MATERIALIZED(
  SELECT order_id,bool_or(lookup_url IS NOT NULL OR status::text IN('succeeded','success','issued','valid_invoice','sent','sent_to_misa','sent_to_tax_authority')) issued
  FROM einvoice_jobs WHERE order_id=ANY(p_ids) GROUP BY order_id
 ), job_flags AS MATERIALIZED(
  SELECT j.order_id,
   bool_or(j.status IN('valid_invoice','resolved') OR j.invoice_number IS NOT NULL OR j.tax_authority_code IS NOT NULL) issued,
   bool_or(j.status IN('sent_to_misa','sent_to_tax_authority') OR j.misa_ref_id IS NOT NULL OR j.transaction_id IS NOT NULL
    OR j.dispatch_claim_id IS NOT NULL OR coalesce(j.dispatch_attempts,0)>0) processing,
   bool_or(j.status NOT IN('pending','pending_manual_config','dispatch_paused') OR j.store_id IS DISTINCT FROM o.restaurant_id OR j.tax_entity_id IS DISTINCT FROM r.tax_entity_id OR j.source_system IS DISTINCT FROM 'restaurant_pos') unusual
  FROM meinvoice_jobs j JOIN orders o ON o.id=j.order_id JOIN restaurants r ON r.id=o.restaurant_id WHERE j.order_id=ANY(p_ids) GROUP BY j.order_id
 ), batch_members AS MATERIALIZED(
  SELECT c.receipt_id FROM sales_reporting_claims c WHERE c.source_system='restaurant_pos' AND c.receipt_id=ANY(SELECT unnest(p_ids)::text)
  UNION SELECT m->>'id' FROM sales_reporting_batches b
   JOIN (SELECT DISTINCT r.tax_entity_id,(p.sold_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date business_day
    FROM paid p JOIN orders o ON o.id=p.order_id JOIN restaurants r ON r.id=o.restaurant_id) s
    ON s.tax_entity_id=b.tax_entity_id AND s.business_day=b.business_date
   CROSS JOIN LATERAL jsonb_array_elements(b.members) m
   WHERE b.status IN('generated','confirmed','reported') AND m->>'source'='restaurant_pos' AND m->>'id'=ANY(SELECT unnest(p_ids)::text)
 ), raw AS(
  SELECT o.id order_id,o.restaurant_id store_id,p.gross,p.sold_at,i.buyer_version,
   CASE WHEN i.id IS NULL OR i.store_id IS DISTINCT FROM o.restaurant_id OR i.tax_entity_id IS DISTINCT FROM r.tax_entity_id THEN NULL ELSE jsonb_build_object(
    'id',i.id,'buyer_version',i.buyer_version,'status',i.status,'buyer_number_type',i.buyer_number_type,'buyer_number_value',i.buyer_number_value,
    'buyer_tax_code',i.buyer_tax_code,'buyer_legal_name',i.buyer_legal_name,'buyer_full_name',i.buyer_full_name,'buyer_address',i.buyer_address,
    'buyer_email',i.buyer_email,'buyer_email_cc',i.buyer_email_cc,'buyer_phone',i.buyer_phone,'buyer_unit_code',i.buyer_unit_code,
    'buyer_id',i.buyer_id,'source_note',i.source_note) END buyer,
   CASE WHEN coalesce(j.issued,false) OR coalesce(l.issued,false) OR x.tax_entity_id IS NOT NULL THEN 'issued'
    WHEN coalesce(j.processing,false) OR coalesce(e.attempted,false) THEN 'processing'
    WHEN o.status<>'completed' OR o.order_purpose IS DISTINCT FROM 'customer' OR p.order_id IS NULL OR coalesce(a.amount,0)<>0
     OR r.brand_id='77000000-0000-0000-0000-000000000001' OR r.tax_entity_id IS NULL OR bm.receipt_id IS NOT NULL
     OR coalesce(j.unusual,false) OR p.gross<=0
     OR i.store_id IS DISTINCT FROM o.restaurant_id AND i.id IS NOT NULL
     OR i.tax_entity_id IS DISTINCT FROM r.tax_entity_id AND i.id IS NOT NULL
     OR coalesce(p.wrong_store,false)
     OR i.status IN('exported','completed','cancelled','manual_review') THEN 'review'
    WHEN i.status='ready' THEN 'ready' WHEN i.id IS NOT NULL THEN 'draft' ELSE 'none' END state
  FROM orders o JOIN restaurants r ON r.id=o.restaurant_id LEFT JOIN paid p ON p.order_id=o.id
  LEFT JOIN adjustments a ON a.order_id=o.id LEFT JOIN job_flags j ON j.order_id=o.id
  LEFT JOIN event_flags e ON e.order_id=o.id LEFT JOIN legacy_flags l ON l.order_id=o.id
  LEFT JOIN red_invoice_intakes i ON i.order_id=o.id LEFT JOIN batch_members bm ON bm.receipt_id=o.id::text
  LEFT JOIN sales_external_reporting_protections x ON x.tax_entity_id=r.tax_entity_id AND x.source_system='restaurant_pos'
   AND x.business_date=(p.sold_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
  WHERE o.id=ANY(p_ids)
 ) SELECT order_id,store_id,state,state IN('none','draft','ready'),buyer_version,buyer,gross,sold_at FROM raw;
$$;
REVOKE ALL ON FUNCTION public.pos_late_invoice_order_states(uuid[]) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.pos_late_invoice_context(p_store_id uuid,p_order_id uuid DEFAULT NULL,p_combined_payment_group_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE actor public.users%ROWTYPE;ids uuid[];rows jsonb;v_state text;can_edit boolean;versions jsonb;v_buyer jsonb;total numeric;wait_reason text;
BEGIN
 SELECT * INTO actor FROM users WHERE auth_id=auth.uid() AND is_active LIMIT 1;
 IF NOT FOUND OR actor.role NOT IN('cashier','admin','store_admin','brand_admin','super_admin') THEN RAISE EXCEPTION 'RED_INVOICE_INTAKE_FORBIDDEN'; END IF;
 IF p_store_id IS NULL OR (p_order_id IS NULL)=(p_combined_payment_group_id IS NULL) THEN RAISE EXCEPTION 'LATE_INVOICE_SCOPE_INVALID'; END IF;
 IF NOT is_super_admin() AND NOT EXISTS(SELECT 1 FROM user_accessible_stores(auth.uid()) s(store_id) WHERE s.store_id=p_store_id) THEN RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN'; END IF;
 SELECT array_agg(id ORDER BY id) INTO ids FROM pos_late_invoice_targets(p_store_id,p_order_id,p_combined_payment_group_id) id;
 IF cardinality(ids) IS NULL OR cardinality(ids)>100 OR (SELECT count(*) FROM orders WHERE id=ANY(ids) AND restaurant_id=p_store_id)<>cardinality(ids) THEN RAISE EXCEPTION 'LATE_INVOICE_SCOPE_INVALID'; END IF;
 SELECT jsonb_agg(to_jsonb(s)),bool_and(editable),jsonb_object_agg(order_id::text,coalesce(to_jsonb(buyer_version),'null'::jsonb)),sum(gross),
  CASE WHEN bool_or(state='issued') THEN 'issued' WHEN bool_or(state='processing') THEN 'processing' WHEN bool_or(state='review') THEN 'review'
   WHEN count(DISTINCT (buyer-ARRAY['id','buyer_version','status','source_note'])::text) FILTER(WHERE buyer IS NOT NULL)>1 THEN 'review'
   WHEN bool_or(state='ready') THEN 'ready' WHEN bool_or(state='draft') THEN 'draft' ELSE 'none' END
 INTO rows,can_edit,versions,total,v_state FROM pos_late_invoice_order_states(ids) s;
 -- Unusual links spanning another combined group require operator review;
 -- never silently update only the subset reached through a direct charge.
 IF EXISTS(SELECT 1 FROM payments member JOIN
  (SELECT DISTINCT combined_payment_group_id id FROM payments WHERE order_id=ANY(ids) AND combined_payment_group_id IS NOT NULL AND is_revenue) g
   ON g.id=member.combined_payment_group_id
  WHERE member.is_revenue AND NOT member.order_id=ANY(ids)) THEN can_edit:=false;v_state:='review'; END IF;
 SELECT e->'buyer' INTO v_buyer FROM jsonb_array_elements(rows) e WHERE e->'buyer'<>'null'::jsonb LIMIT 1;
 SELECT CASE WHEN bool_or(manual_action_type='invoice_mapping_required') THEN 'mapping'
  WHEN bool_or(status='pending_manual_config') THEN 'configuration' ELSE 'operator' END INTO wait_reason
 FROM meinvoice_jobs WHERE order_id=ANY(ids);
 RETURN jsonb_build_object('store_id',p_store_id,'order_ids',to_jsonb(ids),'state',v_state,'can_edit',can_edit AND v_state<>'review',
  'versions',versions,'buyer',coalesce(v_buyer,'{}'::jsonb),'gross_amount',total,'wait_reason',wait_reason,
  'store_name',(SELECT name FROM restaurants WHERE id=p_store_id),
  'receipt_number',(SELECT receipt_number FROM digital_receipts WHERE restaurant_id=p_store_id AND
   (p_combined_payment_group_id IS NOT NULL AND combined_payment_group_id=p_combined_payment_group_id OR p_order_id IS NOT NULL AND order_id=p_order_id)
   ORDER BY created_at DESC LIMIT 1));
END $$;
REVOKE ALL ON FUNCTION public.pos_late_invoice_context(uuid,uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_late_invoice_context(uuid,uuid,uuid) TO authenticated;

CREATE FUNCTION public.pos_submit_late_invoice(p_request_id uuid,p_store_id uuid,p_order_id uuid,p_combined_payment_group_id uuid,p_expected_versions jsonb,p_patch jsonb,p_confirm boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE context jsonb;ids uuid[];locked_ids uuid[];request_ids uuid[];previous public.pos_late_invoice_requests%ROWTYPE;
 payload jsonb;kind text;number text;issue jsonb;actor_id uuid;taxid uuid;result jsonb;prior_explicit text;
BEGIN
 context:=pos_late_invoice_context(p_store_id,p_order_id,p_combined_payment_group_id);
 IF p_request_id IS NULL OR p_confirm IS NULL OR jsonb_typeof(p_expected_versions) IS DISTINCT FROM 'object' OR jsonb_typeof(p_patch) IS DISTINCT FROM 'object' OR octet_length(p_patch::text)>16384 OR octet_length(p_expected_versions::text)>8192 THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 payload:=jsonb_build_object('store',p_store_id,'order',p_order_id,'group',p_combined_payment_group_id,'versions',p_expected_versions,'patch',p_patch,'confirm',p_confirm);
 PERFORM pg_advisory_xact_lock(hashtextextended('pos-late-invoice:'||p_request_id::text,0));
 SELECT * INTO previous FROM pos_late_invoice_requests WHERE id=p_request_id;
 IF FOUND THEN
  IF previous.actor_id<>auth.uid() OR previous.store_id<>p_store_id OR previous.payload IS DISTINCT FROM payload THEN RAISE EXCEPTION 'LATE_INVOICE_REQUEST_CONFLICT'; END IF;
  RETURN pos_late_invoice_context(p_store_id,p_order_id,p_combined_payment_group_id)||jsonb_build_object('request_id',p_request_id,'replayed',true);
 END IF;
 SELECT array_agg(x::uuid ORDER BY x::uuid) INTO ids FROM jsonb_array_elements_text(context->'order_ids') x;
 SELECT array_agg(DISTINCT request_id ORDER BY request_id) INTO request_ids FROM(
  SELECT request_id FROM direct_order_financials WHERE order_id=ANY(ids)
  UNION SELECT request_id FROM direct_order_payment_charges WHERE order_id=ANY(ids)) q;
 PERFORM id FROM direct_order_requests WHERE id=ANY(request_ids) ORDER BY id FOR UPDATE;
 -- Serialize against the existing owner-confirmed reporting-batch workflow.
 PERFORM pg_advisory_xact_lock(hashtextextended('sales-reporting:'||s.tax_entity_id::text||':'||s.business_date::text,0))
 FROM (SELECT DISTINCT r.tax_entity_id,(p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date business_date
  FROM payments p JOIN orders o ON o.id=p.order_id JOIN restaurants r ON r.id=o.restaurant_id
  WHERE p.order_id=ANY(ids) AND p.is_revenue) s ORDER BY s.tax_entity_id,s.business_date;
 PERFORM id FROM orders WHERE id=ANY(ids) ORDER BY id FOR UPDATE;
 PERFORM id FROM payments WHERE order_id=ANY(ids) AND is_revenue ORDER BY id FOR UPDATE;
 PERFORM id FROM meinvoice_jobs WHERE order_id=ANY(ids) ORDER BY order_id FOR UPDATE;
 PERFORM id FROM red_invoice_intakes WHERE order_id=ANY(ids) ORDER BY order_id FOR UPDATE;
 SELECT array_agg(id ORDER BY id) INTO locked_ids FROM pos_late_invoice_targets(p_store_id,p_order_id,p_combined_payment_group_id) id;
 IF ids IS DISTINCT FROM locked_ids THEN RAISE EXCEPTION 'POS_BUYER_CHANGED'; END IF;
 context:=pos_late_invoice_context(p_store_id,p_order_id,p_combined_payment_group_id);
 IF context->>'can_edit' IS DISTINCT FROM 'true' THEN RAISE EXCEPTION 'LATE_INVOICE_PROTECTED' USING DETAIL=context->>'state'; END IF;
 IF context->'versions' IS DISTINCT FROM p_expected_versions THEN RAISE EXCEPTION 'POS_BUYER_CHANGED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each(p_patch) e WHERE e.key NOT IN('buyer_number_type','buyer_number_value','buyer_legal_name','buyer_full_name','buyer_address','buyer_email','buyer_email_cc','buyer_phone','buyer_unit_code','buyer_id','source_note') OR jsonb_typeof(e.value)<>'string') THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each_text(p_patch) e WHERE length(e.value)>CASE e.key WHEN 'buyer_number_value' THEN 64 WHEN 'buyer_id' THEN 64 WHEN 'buyer_email' THEN 254 WHEN 'buyer_email_cc' THEN 1000 WHEN 'buyer_phone' THEN 30 WHEN 'buyer_legal_name' THEN 300 WHEN 'buyer_full_name' THEN 300 WHEN 'buyer_unit_code' THEN 100 ELSE 500 END) THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 kind:=coalesce(p_patch->>'buyer_number_type','vn_tax');number:=coalesce(p_patch->>'buyer_number_value','');
 IF kind NOT IN('vn_tax','household_id','personal_id','foreign_tax','passport') THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 IF p_confirm THEN
  issue:=pos_buyer_number_issue(kind,number);
  IF issue IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_NUMBER_INVALID' USING DETAIL=issue::text; END IF;
  IF nullif(btrim(p_patch->>'buyer_address'),'') IS NULL OR coalesce(p_patch->>'buyer_email','') NOT LIKE '%@%' OR
   nullif(btrim(CASE WHEN kind IN('personal_id','passport') THEN p_patch->>'buyer_full_name' ELSE p_patch->>'buyer_legal_name' END),'') IS NULL THEN RAISE EXCEPTION 'RED_INVOICE_BUYER_INFORMATION_INCOMPLETE'; END IF;
  IF kind IN('vn_tax','household_id') AND coalesce(p_patch->>'buyer_id','')<>'' AND pos_buyer_number_issue('personal_id',p_patch->>'buyer_id') IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 END IF;
 SELECT id INTO STRICT actor_id FROM users WHERE auth_id=auth.uid() AND is_active LIMIT 1;
 SELECT r.tax_entity_id INTO taxid FROM restaurants r JOIN tax_entity t ON t.id=r.tax_entity_id WHERE r.id=p_store_id AND nullif(t.tax_code,'') IS NOT NULL AND t.tax_code<>'PLACEHOLDER_DEV_000';
 IF taxid IS NULL THEN RAISE EXCEPTION 'TAX_ENTITY_NOT_READY'; END IF;
 prior_explicit:=current_setting('globos.pos_buyer_explicit',true);
 PERFORM set_config('globos.pos_buyer_explicit','true',true);
 WITH paid AS MATERIALIZED(
  SELECT p.order_id,array_agg(p.id::text ORDER BY p.created_at,p.id) receipts,min(p.created_at) sale_at,sum(coalesce(p.amount_portion,p.amount)) gross,
   array_agg(DISTINCT p.method ORDER BY p.method) methods,
   jsonb_agg(jsonb_build_object('payment_id',p.id,'amount',p.amount,'amount_portion',coalesce(p.amount_portion,p.amount),'method',p.method,'created_at',p.created_at) ORDER BY p.created_at,p.id) payments
  FROM payments p WHERE p.order_id=ANY(ids) AND p.restaurant_id=p_store_id AND p.is_revenue GROUP BY p.order_id
 ), items AS MATERIALIZED(
  SELECT i.order_id,jsonb_agg(jsonb_build_object('order_item_id',tax_line.order_item_id,'source_order_item_id',i.id,'display_name',tax_line.display_name,
   'item_type',i.item_type,'quantity',tax_line.quantity,'unit_price',tax_line.unit_price,'vat_rate',tax_line.vat_rate,'vat_amount',tax_line.vat_amount,'total_amount_ex_tax',tax_line.total_amount_ex_tax,'paying_amount_inc_tax',tax_line.paying_amount_inc_tax) ORDER BY i.created_at,i.id,tax_line.vat_rate) lines
  FROM order_items i LEFT JOIN meinvoice_jobs existing_job ON existing_job.order_id=i.order_id
  CROSS JOIN LATERAL order_item_invoice_tax_lines(i) tax_line
  WHERE i.order_id=ANY(ids) AND i.status<>'cancelled' AND existing_job.id IS NULL GROUP BY i.order_id
 ), jobs AS(
  INSERT INTO meinvoice_jobs(order_id,store_id,tax_entity_id,buyer_kind,buyer_snapshot,payment_method_snapshot,payment_summary,line_items_snapshot,status)
  SELECT p.order_id,p_store_id,taxid,CASE WHEN p_confirm THEN 'registered' ELSE 'manual' END,
   jsonb_build_object('tax_code',CASE WHEN kind IN('personal_id','passport') THEN '' ELSE number END,'tin_cic_household_head_id',CASE WHEN kind IN('personal_id','passport') THEN '' ELSE number END,
    'unit_name',coalesce(p_patch->>'buyer_legal_name',''),'buyer_full_name',coalesce(p_patch->>'buyer_full_name',''),'address',coalesce(p_patch->>'buyer_address',''),
    'email',coalesce(p_patch->>'buyer_email',''),'email_cc',coalesce(p_patch->>'buyer_email_cc',''),'phone',coalesce(p_patch->>'buyer_phone',''),
    'unit_code',coalesce(p_patch->>'buyer_unit_code',''),'buyer_id',CASE WHEN kind IN('personal_id','passport') THEN number ELSE coalesce(p_patch->>'buyer_id','') END,'source','red_invoice_intake'),
   meinvoice_payment_method_label(taxid,p.methods),p.payments,coalesce(i.lines,'[]'::jsonb),'dispatch_paused'
  FROM paid p LEFT JOIN items i ON i.order_id=p.order_id
  ON CONFLICT(order_id) DO UPDATE SET buyer_kind=EXCLUDED.buyer_kind,buyer_snapshot=EXCLUDED.buyer_snapshot,status='dispatch_paused',updated_at=clock_timestamp()
  RETURNING *
 ) INSERT INTO red_invoice_intakes(order_id,store_id,tax_entity_id,meinvoice_job_id,receipt_ids,sale_at,gross_amount,payment_method,line_items_snapshot,
  source,status,buyer_number_type,buyer_number_value,buyer_tax_code,buyer_legal_name,buyer_full_name,buyer_address,buyer_email,buyer_email_cc,buyer_phone,buyer_unit_code,buyer_id,source_note,requested_by,updated_by,ready_at)
 SELECT p.order_id,p_store_id,taxid,j.id,p.receipts,p.sale_at,p.gross,j.payment_method_snapshot,j.line_items_snapshot,'cashier',CASE WHEN p_confirm THEN 'ready' ELSE 'awaiting_information' END,
  kind,number,CASE WHEN kind NOT IN('personal_id','passport') THEN nullif(number,'') END,nullif(p_patch->>'buyer_legal_name',''),nullif(p_patch->>'buyer_full_name',''),nullif(p_patch->>'buyer_address',''),
  nullif(p_patch->>'buyer_email',''),nullif(p_patch->>'buyer_email_cc',''),nullif(p_patch->>'buyer_phone',''),nullif(p_patch->>'buyer_unit_code',''),CASE WHEN kind IN('personal_id','passport') THEN nullif(number,'') ELSE nullif(p_patch->>'buyer_id','') END,
  nullif(p_patch->>'source_note',''),actor_id,actor_id,CASE WHEN p_confirm THEN now() END
 FROM paid p JOIN jobs j ON j.order_id=p.order_id
 ON CONFLICT(order_id) DO UPDATE SET meinvoice_job_id=EXCLUDED.meinvoice_job_id,status=EXCLUDED.status,buyer_number_type=EXCLUDED.buyer_number_type,buyer_number_value=EXCLUDED.buyer_number_value,
  buyer_tax_code=EXCLUDED.buyer_tax_code,buyer_legal_name=EXCLUDED.buyer_legal_name,buyer_full_name=EXCLUDED.buyer_full_name,buyer_address=EXCLUDED.buyer_address,
  buyer_email=EXCLUDED.buyer_email,buyer_email_cc=EXCLUDED.buyer_email_cc,buyer_phone=EXCLUDED.buyer_phone,buyer_unit_code=EXCLUDED.buyer_unit_code,buyer_id=EXCLUDED.buyer_id,
  source_note=EXCLUDED.source_note,updated_by=EXCLUDED.updated_by,updated_at=clock_timestamp(),ready_at=CASE WHEN p_confirm THEN coalesce(red_invoice_intakes.ready_at,now()) ELSE NULL END;
 -- Keep Direct Order's request snapshot aligned without invoking a second writer.
 UPDATE direct_order_requests SET invoice_details=invoice_details||jsonb_build_object('requested',true,'pos_only',true,'buyer_confirmed',p_confirm,
  'number_type',kind,'number_value',number,'tax_code',CASE WHEN kind IN('personal_id','passport') THEN '' ELSE number END,
  'legal_name',coalesce(p_patch->>'buyer_legal_name',''),'full_name',coalesce(p_patch->>'buyer_full_name',''),'address',coalesce(p_patch->>'buyer_address',''),
  'email',coalesce(p_patch->>'buyer_email',''),'email_cc',coalesce(p_patch->>'buyer_email_cc',''),'phone',coalesce(p_patch->>'buyer_phone',''),
  'unit_code',coalesce(p_patch->>'buyer_unit_code',''),'buyer_id',CASE WHEN kind IN('personal_id','passport') THEN number ELSE coalesce(p_patch->>'buyer_id','') END),support_version=support_version+1
 WHERE id=ANY(request_ids);
 PERFORM set_config('globos.pos_buyer_explicit',coalesce(prior_explicit,''),true);
 result:=pos_late_invoice_context(p_store_id,p_order_id,p_combined_payment_group_id)||jsonb_build_object('request_id',p_request_id,'replayed',false);
 INSERT INTO pos_late_invoice_requests VALUES(p_request_id,auth.uid(),p_store_id,payload,result,now());
 INSERT INTO audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'pos_late_red_invoice_request','pos_late_invoice_requests',p_request_id,
  jsonb_build_object('store_id',p_store_id,'order_ids',to_jsonb(ids),'reason','cashier_omission','confirmed',p_confirm,'previous_versions',p_expected_versions,'versions',result->'versions'));
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.pos_submit_late_invoice(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.pos_submit_late_invoice(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean) TO authenticated;

-- Annotate only the bounded, already-authorized page with a single set query.
ALTER FUNCTION public.get_receipt_ledger_page(date,uuid,text,text,integer,integer,timestamptz,text,boolean) RENAME TO get_receipt_ledger_page_before_late_invoice;
REVOKE ALL ON FUNCTION public.get_receipt_ledger_page_before_late_invoice(date,uuid,text,text,integer,integer,timestamptz,text,boolean) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.get_receipt_ledger_page(p_business_date date,p_store_id uuid DEFAULT NULL,p_query text DEFAULT NULL,p_status text DEFAULT NULL,p_limit integer DEFAULT 50,p_offset integer DEFAULT 0,p_after_at timestamptz DEFAULT NULL,p_after_id text DEFAULT NULL,p_include_summary boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE page jsonb;ids uuid[];receipts jsonb;
BEGIN
 page:=get_receipt_ledger_page_before_late_invoice(p_business_date,p_store_id,p_query,p_status,p_limit,p_offset,p_after_at,p_after_id,p_include_summary);
 SELECT array_agg(DISTINCT x::uuid) INTO ids FROM jsonb_array_elements(page->'receipts') r CROSS JOIN LATERAL jsonb_array_elements_text(r->'order_ids') x WHERE r->>'receipt_source'='pos';
 WITH states AS MATERIALIZED(SELECT * FROM pos_late_invoice_order_states(coalesce(ids,'{}'))),
 rows AS(SELECT r,ord,CASE WHEN bool_or(s.state='issued') THEN 'issued' WHEN bool_or(s.state='processing') THEN 'processing'
  WHEN bool_or(s.state='review') THEN 'review' WHEN bool_or(s.state='ready') THEN 'ready' WHEN bool_or(s.state='draft') THEN 'draft' ELSE 'none' END state
  FROM jsonb_array_elements(page->'receipts') WITH ORDINALITY q(r,ord)
  LEFT JOIN LATERAL jsonb_array_elements_text(r->'order_ids') x ON r->>'receipt_source'='pos'
  LEFT JOIN states s ON s.order_id=x::uuid GROUP BY r,ord)
 SELECT coalesce(jsonb_agg(r||jsonb_build_object('invoice_state',CASE WHEN r->>'receipt_source'='pos' THEN state ELSE 'unavailable' END) ORDER BY ord),'[]') INTO receipts FROM rows;
 RETURN page||jsonb_build_object('receipts',receipts);
END $$;
REVOKE ALL ON FUNCTION public.get_receipt_ledger_page(date,uuid,text,text,integer,integer,timestamptz,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_receipt_ledger_page(date,uuid,text,text,integer,integer,timestamptz,text,boolean) TO authenticated;

DO $verify$ BEGIN
 IF has_function_privilege('anon','public.pos_submit_late_invoice(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean)','EXECUTE')
 OR has_function_privilege('authenticated','public.pos_late_invoice_order_states(uuid[])','EXECUTE')
 OR has_table_privilege('authenticated','public.pos_late_invoice_requests','INSERT') THEN RAISE EXCEPTION 'LATE_INVOICE_PERMISSION_DRIFT'; END IF;
END $verify$;
COMMIT;
