-- Frozen reporting membership; owner confirmation and external evidence are separate.
-- No tax submission or invoice dispatch occurs in these functions.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.sales_reporting_batches (
 id uuid PRIMARY KEY, business_date date NOT NULL, tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),
 source_revision text NOT NULL, mapping_revision bigint NOT NULL,
 status text NOT NULL DEFAULT 'draft' CHECK(status IN('draft','generated','confirmed','reported','void')),
 members jsonb NOT NULL CHECK(jsonb_array_length(members) BETWEEN 1 AND 10000),
 receipt_count integer NOT NULL, gross numeric NOT NULL, membership_hash text NOT NULL,
 file_sha256 text, file_size bigint, created_by uuid NOT NULL REFERENCES auth.users(id),created_at timestamptz NOT NULL DEFAULT now(),
 confirmed_by uuid REFERENCES auth.users(id),confirmed_at timestamptz,
 external_evidence jsonb, reported_by uuid REFERENCES auth.users(id),reported_at timestamptz,
 void_reason text, voided_by uuid REFERENCES auth.users(id),voided_at timestamptz
);
CREATE INDEX sales_reporting_batches_scope ON public.sales_reporting_batches(tax_entity_id,business_date,created_at DESC,id);
CREATE TABLE public.sales_reporting_claims (
 source_system text NOT NULL,receipt_id text NOT NULL,batch_id uuid NOT NULL REFERENCES public.sales_reporting_batches(id),
 business_date date NOT NULL,tax_entity_id uuid NOT NULL,store_id uuid NOT NULL,source_hash text NOT NULL,gross numeric NOT NULL,
 PRIMARY KEY(source_system,receipt_id)
);
CREATE INDEX sales_reporting_claims_scope ON public.sales_reporting_claims(tax_entity_id,business_date);
ALTER TABLE public.sales_reporting_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_reporting_claims ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sales_reporting_batches,public.sales_reporting_claims FROM PUBLIC,anon,authenticated;

-- A single bounded set query per source, never an RPC/SELECT per receipt.
CREATE FUNCTION public.sales_reporting_members_v1(p_date date,p_entity uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE ids uuid[]; photos jsonb; result jsonb;
BEGIN
 SELECT array_agg(order_id) INTO ids FROM pos_daily_receipt_scope_page(p_date,p_entity,NULL,NULL,10001);
 SELECT coalesce(jsonb_agg(jsonb_build_object('source','photo_objet_moers','id',source_hash,'store_id',store_id,'store_name',store_name,
  'store_code',NULL,'name_origin','current_registry','source_hash',md5(jsonb_build_array(source_hash,store_id,sold_at,amount)::text),'gross',amount) ORDER BY sold_at,source_hash),'[]') INTO photos
 FROM pos_photo_receipt_rows_page(p_date,p_entity,NULL,NULL,10001);
 IF coalesce(cardinality(ids),0)+jsonb_array_length(photos)>10000 THEN RAISE EXCEPTION 'SALES_BATCH_LIMIT_10000'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('source','restaurant_pos','id',r.receipt_id,'store_id',r.store_id,'store_name',r.store_name,
  'store_code',CASE WHEN si.order_id IS NULL THEN shop.short_code ELSE si.store_code END,'name_origin',CASE WHEN si.order_id IS NULL THEN 'current_registry' ELSE 'order_snapshot' END,
  'source_hash',r.source_hash,'gross',r.gross_sales) ORDER BY r.sold_at,r.receipt_id),'[]')||photos INTO result
 FROM pos_restaurant_receipt_rows_v2(p_date,coalesce(ids,'{}')) r
 LEFT JOIN store_sale_identities si ON si.order_id=r.receipt_id::uuid LEFT JOIN restaurants shop ON shop.id=r.store_id WHERE r.tax_entity_id=p_entity;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.sales_reporting_members_v1(date,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.admin_prepare_sales_batch_v1(p_id uuid,p_date date,p_entity uuid,p_source_revision text,p_mapping_revision bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b sales_reporting_batches; all_members jsonb; selected jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF p_id IS NULL OR p_date IS NULL OR p_date<DATE '2020-01-01' OR p_date>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR p_entity IS NULL THEN RAISE EXCEPTION 'SALES_BATCH_SCOPE_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('sales-reporting:'||p_entity::text||':'||p_date::text,0));
 SELECT * INTO b FROM sales_reporting_batches WHERE id=p_id;
 IF FOUND THEN
  IF (b.business_date,b.tax_entity_id,b.source_revision,b.mapping_revision,b.created_by) IS DISTINCT FROM (p_date,p_entity,p_source_revision,p_mapping_revision,auth.uid()) THEN RAISE EXCEPTION 'SALES_BATCH_REQUEST_CONFLICT'; END IF;
  RETURN to_jsonb(b);
 END IF;
 IF p_source_revision IS DISTINCT FROM pos_sales_export_source_revision(p_date,p_entity)
 OR p_mapping_revision IS DISTINCT FROM coalesce((SELECT revision FROM sales_invoice_mapping_revisions WHERE tax_entity_id=p_entity),0) THEN RAISE EXCEPTION 'SALES_BATCH_SOURCE_CHANGED'; END IF;
 IF EXISTS(SELECT 1 FROM sales_external_reporting_protections WHERE business_date=p_date AND tax_entity_id=p_entity) THEN RAISE EXCEPTION 'SALES_EXPORT_EXTERNALLY_REPORTED'; END IF;
 all_members:=sales_reporting_members_v1(p_date,p_entity);
 -- A previously confirmed receipt may not disappear or change silently. Corrections
 -- remain in the invoice owner's workflow; an unreported batch can be voided.
 IF EXISTS(WITH current_members AS MATERIALIZED(SELECT * FROM jsonb_array_elements(all_members))
 SELECT 1 FROM sales_reporting_claims c LEFT JOIN current_members m ON m.value->>'source'=c.source_system AND m.value->>'id'=c.receipt_id
 WHERE c.tax_entity_id=p_entity AND c.business_date=p_date
 AND (m.value IS NULL OR (m.value->>'source_hash',(m.value->>'store_id')::uuid,(m.value->>'gross')::numeric) IS DISTINCT FROM (c.source_hash,c.store_id,c.gross))) THEN RAISE EXCEPTION 'SALES_BATCH_RECONCILIATION_REQUIRED'; END IF;
 SELECT coalesce(jsonb_agg(m ORDER BY m->>'source',m->>'id'),'[]') INTO selected FROM jsonb_array_elements(all_members)m
 LEFT JOIN sales_reporting_claims c ON c.source_system=m->>'source' AND c.receipt_id=m->>'id' WHERE c.batch_id IS NULL;
 IF jsonb_array_length(selected)=0 THEN RAISE EXCEPTION 'SALES_BATCH_NO_NEW_RECEIPTS'; END IF;
 INSERT INTO sales_reporting_batches(id,business_date,tax_entity_id,source_revision,mapping_revision,members,receipt_count,gross,membership_hash,created_by)
 SELECT p_id,p_date,p_entity,p_source_revision,p_mapping_revision,selected,jsonb_array_length(selected),sum((m->>'gross')::numeric),md5(selected::text),auth.uid() FROM jsonb_array_elements(selected)m RETURNING * INTO b;
 RETURN to_jsonb(b);
END $$;

CREATE FUNCTION public.admin_update_sales_batch_v1(p_id uuid,p_action text,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b sales_reporting_batches; current_members jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 SELECT * INTO b FROM sales_reporting_batches WHERE id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'SALES_BATCH_NOT_FOUND'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('sales-reporting:'||b.tax_entity_id::text||':'||b.business_date::text,0));
 SELECT * INTO b FROM sales_reporting_batches WHERE id=p_id FOR UPDATE;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' OR octet_length(p_payload::text)>4096 THEN RAISE EXCEPTION 'SALES_BATCH_PAYLOAD_INVALID'; END IF;
 IF p_action='generated' THEN
  IF coalesce(p_payload->>'sha256','')!~'^[a-f0-9]{64}$' OR coalesce((p_payload->>'size')::bigint,0) NOT BETWEEN 1 AND 104857600 THEN RAISE EXCEPTION 'SALES_BATCH_FILE_INVALID'; END IF;
  IF b.status<>'draft' THEN
   IF b.status IN('generated','confirmed','reported') AND b.file_sha256=p_payload->>'sha256' AND b.file_size=(p_payload->>'size')::bigint THEN RETURN to_jsonb(b); END IF;
   RAISE EXCEPTION 'SALES_BATCH_FILE_CONFLICT';
  END IF;
  -- Hash is a client-declared artifact digest, not evidence of transmission.
  UPDATE sales_reporting_batches SET status='generated',file_sha256=p_payload->>'sha256',file_size=(p_payload->>'size')::bigint WHERE id=p_id;
 ELSIF p_action='confirm' THEN
  IF p_payload->>'sha256' IS DISTINCT FROM b.file_sha256 THEN RAISE EXCEPTION 'SALES_BATCH_FILE_CONFLICT'; END IF;
  IF b.status IN('confirmed','reported') THEN RETURN to_jsonb(b); END IF;
  IF b.status<>'generated' THEN RAISE EXCEPTION 'SALES_BATCH_NOT_GENERATED'; END IF;
  IF b.source_revision IS DISTINCT FROM pos_sales_export_source_revision(b.business_date,b.tax_entity_id)
   OR b.mapping_revision IS DISTINCT FROM coalesce((SELECT revision FROM sales_invoice_mapping_revisions WHERE tax_entity_id=b.tax_entity_id),0) THEN RAISE EXCEPTION 'SALES_BATCH_SOURCE_CHANGED'; END IF;
  IF EXISTS(SELECT 1 FROM sales_external_reporting_protections WHERE business_date=b.business_date AND tax_entity_id=b.tax_entity_id) THEN RAISE EXCEPTION 'SALES_EXPORT_EXTERNALLY_REPORTED'; END IF;
  current_members:=sales_reporting_members_v1(b.business_date,b.tax_entity_id);
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(b.members)m LEFT JOIN jsonb_array_elements(current_members)c ON c->>'source'=m->>'source' AND c->>'id'=m->>'id'
    WHERE c IS NULL OR (c->>'source_hash',c->>'store_id',c->>'gross') IS DISTINCT FROM (m->>'source_hash',m->>'store_id',m->>'gross')) THEN RAISE EXCEPTION 'SALES_BATCH_SOURCE_CHANGED'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(b.members)m JOIN sales_reporting_claims c ON c.source_system=m->>'source' AND c.receipt_id=m->>'id') THEN RAISE EXCEPTION 'SALES_BATCH_RECEIPT_ALREADY_CONFIRMED'; END IF;
  INSERT INTO sales_reporting_claims SELECT m->>'source',m->>'id',p_id,b.business_date,b.tax_entity_id,(m->>'store_id')::uuid,m->>'source_hash',(m->>'gross')::numeric FROM jsonb_array_elements(b.members)m;
  UPDATE sales_reporting_batches SET status='confirmed',confirmed_by=auth.uid(),confirmed_at=now() WHERE id=p_id;
 ELSIF p_action='reported' THEN
  IF p_payload->>'sha256' IS DISTINCT FROM b.file_sha256 OR length(btrim(coalesce(p_payload->>'channel',''))) NOT BETWEEN 1 AND 80
   OR length(btrim(coalesce(p_payload->>'recipient',''))) NOT BETWEEN 1 AND 200 OR length(btrim(coalesce(p_payload->>'reference',''))) NOT BETWEEN 1 AND 1000 THEN RAISE EXCEPTION 'SALES_BATCH_EXTERNAL_EVIDENCE_REQUIRED'; END IF;
  IF b.status='reported' AND b.external_evidence=p_payload THEN RETURN to_jsonb(b); END IF;
  IF b.status<>'confirmed' THEN RAISE EXCEPTION 'SALES_BATCH_NOT_CONFIRMED'; END IF;
  UPDATE sales_reporting_batches SET status='reported',external_evidence=p_payload,reported_by=auth.uid(),reported_at=now() WHERE id=p_id;
 ELSIF p_action='void' THEN
  IF length(btrim(coalesce(p_payload->>'reason',''))) NOT BETWEEN 5 AND 1000 THEN RAISE EXCEPTION 'SALES_BATCH_REASON_REQUIRED'; END IF;
  IF b.status='reported' THEN RAISE EXCEPTION 'SALES_BATCH_REPORTED_IMMUTABLE'; END IF;
  IF b.status='void' THEN RETURN to_jsonb(b); END IF;
  DELETE FROM sales_reporting_claims WHERE batch_id=p_id;
  UPDATE sales_reporting_batches SET status='void',void_reason=p_payload->>'reason',voided_by=auth.uid(),voided_at=now() WHERE id=p_id;
 ELSE RAISE EXCEPTION 'SALES_BATCH_ACTION_INVALID'; END IF;
 SELECT * INTO b FROM sales_reporting_batches WHERE id=p_id;
 RETURN to_jsonb(b);
END $$;
CREATE FUNCTION public.admin_list_sales_batches_v1(p_date date,p_entity uuid,p_before timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 RETURN coalesce((SELECT jsonb_agg(to_jsonb(b) ORDER BY created_at DESC,id) FROM (
 SELECT id,business_date,tax_entity_id,status,receipt_count,gross,file_sha256,file_size,created_at,confirmed_by,confirmed_at,reported_at,external_evidence,void_reason FROM sales_reporting_batches WHERE business_date=p_date AND tax_entity_id=p_entity AND (p_before IS NULL OR created_at<p_before OR (created_at=p_before AND id>p_before_id)) ORDER BY created_at DESC,id LIMIT 20)b),'[]');
END $$;
REVOKE ALL ON FUNCTION public.admin_prepare_sales_batch_v1(uuid,date,uuid,text,bigint),public.admin_update_sales_batch_v1(uuid,text,jsonb),public.admin_list_sales_batches_v1(date,uuid,timestamptz,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_prepare_sales_batch_v1(uuid,date,uuid,text,bigint),public.admin_update_sales_batch_v1(uuid,text,jsonb),public.admin_list_sales_batches_v1(date,uuid,timestamptz,uuid) TO authenticated;
COMMIT;
