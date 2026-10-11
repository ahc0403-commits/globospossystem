BEGIN;
-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='120s';
CREATE TABLE public.sales_invoice_mapping_revisions(tax_entity_id uuid PRIMARY KEY REFERENCES public.tax_entity(id),revision bigint NOT NULL DEFAULT 0);
ALTER TABLE public.sales_invoice_mapping_revisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sales_invoice_mapping_revisions FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.bump_sales_invoice_mapping_revision() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 INSERT INTO public.sales_invoice_mapping_revisions(tax_entity_id,revision) VALUES(NEW.tax_entity_id,1)
 ON CONFLICT(tax_entity_id) DO UPDATE SET revision=sales_invoice_mapping_revisions.revision+1;
 RETURN NEW;
END $$;
CREATE TRIGGER menu_invoice_mapping_revision AFTER INSERT OR UPDATE ON public.menu_invoice_profiles FOR EACH ROW EXECUTE FUNCTION public.bump_sales_invoice_mapping_revision();
CREATE TRIGGER item_type_invoice_mapping_revision AFTER INSERT OR UPDATE ON public.item_type_invoice_profiles FOR EACH ROW EXECUTE FUNCTION public.bump_sales_invoice_mapping_revision();
REVOKE ALL ON FUNCTION public.bump_sales_invoice_mapping_revision() FROM PUBLIC,anon,authenticated;
-- A statement-consistent fingerprint of the scoped source. No receipt RPCs and
-- no changes to checkout/payment writes. The checksum never returns buyer PII.
CREATE FUNCTION public.pos_sales_export_source_revision(p_business_date date,p_tax_entity_id uuid) RETURNS text
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH scope AS MATERIALIZED(SELECT * FROM public.pos_daily_receipt_scope(p_business_date) WHERE tax_entity_id=p_tax_entity_id),
 items AS(SELECT item.order_id,item.id,item.menu_item_id,item.item_type,item.status,item.is_service_item,item.quantity,item.unit_price,item.total_amount_ex_tax,item.vat_rate,item.vat_amount,item.vat_breakdown,item.paying_amount_inc_tax FROM public.order_items item JOIN scope s ON s.order_id=item.order_id),
 payments AS(SELECT p.order_id,p.id,p.method,p.amount,p.amount_portion,p.created_at,p.is_revenue FROM public.payments p JOIN scope s ON s.order_id=p.order_id),
 jobs AS(SELECT j.order_id,j.id,j.snapshot_version,j.line_items_snapshot,j.buyer_snapshot,j.payment_method_snapshot,j.payment_summary,j.status,j.misa_ref_id,j.invoice_number,j.dispatch_claim_id,j.dispatch_attempts FROM public.meinvoice_jobs j JOIN scope s ON s.order_id=j.order_id WHERE j.source_system='restaurant_pos'),
 contacts AS(SELECT i.* FROM public.red_invoice_intakes i JOIN scope s ON s.order_id=i.order_id),
 photo AS(SELECT * FROM public.pos_photo_receipt_rows(p_business_date) WHERE tax_entity_id=p_tax_entity_id)
 SELECT md5(jsonb_build_object('scope',(SELECT jsonb_agg(to_jsonb(s) ORDER BY order_id) FROM scope s),
 'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY order_id,id) FROM items i),
 'payments',(SELECT jsonb_agg(to_jsonb(p) ORDER BY order_id,id) FROM payments p),
 'jobs',(SELECT jsonb_agg(to_jsonb(j) ORDER BY order_id,id) FROM jobs j),
 'contacts',(SELECT jsonb_agg(to_jsonb(i) ORDER BY order_id,id) FROM contacts i),
 'photo',(SELECT jsonb_agg(to_jsonb(p) ORDER BY sold_at,source_hash) FROM photo p))::text);
$$;
REVOKE ALL ON FUNCTION public.pos_sales_export_source_revision(date,uuid) FROM PUBLIC,anon,authenticated;
DO $patch$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.get_pos_daily_sales_summary(date)'::regprocedure) INTO d;
 IF strpos(d,'''restaurant_receipt_count'',COALESCE(r.receipt_count,0)')=0 THEN RAISE EXCEPTION 'SALES_SUMMARY_CONTRACT_ANCHOR_CHANGED'; END IF;
 d:=replace(d,'''restaurant_receipt_count'',COALESCE(r.receipt_count,0)',
 '''source_revision'',public.pos_sales_export_source_revision(p_business_date,e.tax_entity_id),''mapping_revision'',COALESCE((SELECT revision FROM public.sales_invoice_mapping_revisions WHERE tax_entity_id=e.tax_entity_id),0),''externally_reported'',EXISTS(SELECT 1 FROM public.sales_external_reporting_protections x WHERE x.business_date=p_business_date AND x.tax_entity_id=e.tax_entity_id),''source_item_count'',(SELECT count(*) FROM public.order_items item JOIN paid scope ON scope.order_id=item.order_id WHERE scope.tax_entity_id=e.tax_entity_id AND item.status<>''cancelled'' AND COALESCE(item.is_service_item,false)=false)+COALESCE(p.receipt_count,0),''export_line_count'',(SELECT COALESCE(sum(CASE WHEN item.vat_rate=-1 THEN jsonb_array_length(item.vat_breakdown) ELSE 1 END),0) FROM public.order_items item JOIN paid scope ON scope.order_id=item.order_id WHERE scope.tax_entity_id=e.tax_entity_id AND item.status<>''cancelled'' AND COALESCE(item.is_service_item,false)=false)+COALESCE(p.receipt_count,0),''restaurant_receipt_count'',COALESCE(r.receipt_count,0)');
 EXECUTE d;
 SELECT pg_get_functiondef('public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)'::regprocedure) INTO d;
 IF strpos(d,'''rows'',result')=0 THEN RAISE EXCEPTION 'SALES_PAGE_CONTRACT_ANCHOR_CHANGED'; END IF;
 d:=replace(d,'''rows'',result', '''source_revision'',public.pos_sales_export_source_revision(p_business_date,p_tax_entity_id),''mapping_revision'',COALESCE((SELECT revision FROM public.sales_invoice_mapping_revisions WHERE tax_entity_id=p_tax_entity_id),0),''externally_reported'',EXISTS(SELECT 1 FROM public.sales_external_reporting_protections x WHERE x.business_date=p_business_date AND x.tax_entity_id=p_tax_entity_id AND x.source_system=p_source_system),''rows'',result');
 EXECUTE d;
END $patch$;
DO $pages$ DECLARE d text; BEGIN
 SELECT pg_get_functiondef('public.pos_photo_receipt_rows(date)'::regprocedure) INTO d;
 IF strpos(d,'sale_date=p_business_date AND source_identity_version=2 AND amount>0')=0 THEN RAISE EXCEPTION 'PHOTO_PAGE_SOURCE_ANCHOR_CHANGED'; END IF;
 d:=replace(d,'public.pos_photo_receipt_rows(p_business_date date)','public.pos_photo_receipt_rows_page(p_business_date date,p_tax_entity_id uuid,p_after_time timestamptz,p_after_id text,p_limit integer)');
 d:=replace(d,'sale_date=p_business_date AND source_identity_version=2 AND amount>0',
 'sale_date=p_business_date AND source_identity_version=2 AND amount>0 AND (p_after_time IS NULL OR (sold_at,source_hash)>(p_after_time,p_after_id)) AND store_id IN(SELECT id FROM public.restaurants WHERE tax_entity_id=p_tax_entity_id UNION SELECT store_id FROM public.store_tax_entity_history WHERE tax_entity_id=p_tax_entity_id AND effective_from<(p_business_date+1)::timestamp AT TIME ZONE ''Asia/Ho_Chi_Minh'' AND (effective_to IS NULL OR effective_to>p_business_date::timestamp AT TIME ZONE ''Asia/Ho_Chi_Minh''))');
 d:=replace(d,'WHERE seller.id<>','WHERE seller.id=p_tax_entity_id AND seller.id<>');
 d:=replace(d,$old$::uuid;
$old$,$new$::uuid ORDER BY raw.sold_at,raw.source_hash LIMIT p_limit;
$new$);
 EXECUTE d;
 SELECT pg_get_functiondef('public.pos_daily_receipt_scope(date)'::regprocedure) INTO d;
 IF strpos(d,'SELECT DISTINCT order_id FROM public.payments WHERE is_revenue')=0 THEN RAISE EXCEPTION 'RESTAURANT_PAGE_SOURCE_ANCHOR_CHANGED'; END IF;
 d:=replace(d,'public.pos_daily_receipt_scope(p_business_date date)','public.pos_daily_receipt_scope_page(p_business_date date,p_tax_entity_id uuid,p_after_time timestamptz,p_after_id text,p_limit integer)');
 d:=replace(d,'SELECT DISTINCT order_id FROM public.payments WHERE is_revenue',
 'SELECT DISTINCT order_id FROM public.payments WHERE is_revenue AND (p_after_time IS NULL OR (created_at,order_id::text)>(p_after_time,p_after_id)) AND (restaurant_id IN(SELECT id FROM public.restaurants WHERE tax_entity_id=p_tax_entity_id UNION SELECT store_id FROM public.store_tax_entity_history WHERE tax_entity_id=p_tax_entity_id AND effective_from<(p_business_date+1)::timestamp AT TIME ZONE ''Asia/Ho_Chi_Minh'' AND (effective_to IS NULL OR effective_to>p_business_date::timestamp AT TIME ZONE ''Asia/Ho_Chi_Minh'')) OR order_id IN(SELECT order_id FROM public.meinvoice_jobs WHERE source_system=''restaurant_pos'' AND tax_entity_id=p_tax_entity_id))');
 d:=replace(d,'WHERE COALESCE(j.tax_entity_id,h.tax_entity_id,r.tax_entity_id)<>','WHERE COALESCE(j.tax_entity_id,h.tax_entity_id,r.tax_entity_id)=p_tax_entity_id AND (p_after_time IS NULL OR (p.sold_at,p.order_id::text)>(p_after_time,p_after_id)) AND COALESCE(j.tax_entity_id,h.tax_entity_id,r.tax_entity_id)<>');
 d:=replace(d,$old$::uuid;
$old$,$new$::uuid ORDER BY p.sold_at,p.order_id LIMIT p_limit;
$new$);
 EXECUTE d;
 SELECT pg_get_functiondef('public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)'::regprocedure) INTO d;
 d:=replace(d,'public.pos_daily_receipt_scope(p_business_date)','public.pos_daily_receipt_scope_page(p_business_date,p_tax_entity_id,p_after_time,p_after_id,p_limit)');
 d:=replace(d,'public.pos_photo_receipt_rows(p_business_date)','public.pos_photo_receipt_rows_page(p_business_date,p_tax_entity_id,p_after_time,p_after_id,p_limit)');
 EXECUTE d;
END $pages$;
REVOKE ALL ON FUNCTION public.pos_photo_receipt_rows_page(date,uuid,timestamptz,text,integer),public.pos_daily_receipt_scope_page(date,uuid,timestamptz,text,integer) FROM PUBLIC,anon,authenticated;
-- Cursor and potential seller stores are applied to candidates before the
-- materialized history/payment joins. Final seller resolution still preserves
-- historical ownership and job attribution. An index bounds each day scan.
CREATE INDEX IF NOT EXISTS payments_revenue_sale_day_order ON public.payments(created_at,order_id) WHERE is_revenue;
CREATE INDEX IF NOT EXISTS payments_revenue_order_sale ON public.payments(order_id,created_at) WHERE is_revenue;
CREATE INDEX IF NOT EXISTS order_items_invoice_order ON public.order_items(order_id) WHERE status<>'cancelled' AND COALESCE(is_service_item,false)=false;
CREATE INDEX IF NOT EXISTS photo_invoice_sale_cursor ON public.photo_objet_sales_raw(sale_date,sold_at,source_hash) WHERE source_identity_version=2 AND amount>0;
DO $verify$ BEGIN
 IF strpos(pg_get_functiondef('public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)'::regprocedure),'externally_reported')=0
 OR strpos(pg_get_functiondef('public.get_pos_daily_sales_summary(date)'::regprocedure),'export_line_count')=0
 OR has_function_privilege('anon','public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)','EXECUTE') THEN RAISE EXCEPTION 'SALES_PAGE_CONTRACT_DRIFT'; END IF;
END $verify$;
COMMIT;
