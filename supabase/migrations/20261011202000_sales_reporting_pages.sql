BEGIN;
-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
CREATE FUNCTION public.pos_photo_receipt_rows(p_business_date date) RETURNS TABLE(
 tax_entity_id uuid,seller_tax_code text,seller_legal_name text,source_hash text,store_id uuid,store_name text,device_name text,sold_at timestamptz,amount numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH raw_scope AS MATERIALIZED(SELECT raw.* FROM public.photo_objet_sales_raw raw WHERE sale_date=p_business_date AND source_identity_version=2 AND amount>0),
 history AS MATERIALIZED(SELECT DISTINCT ON(raw.source_hash) raw.source_hash,h.tax_entity_id FROM raw_scope raw
 JOIN public.store_tax_entity_history h ON h.store_id=raw.store_id AND h.effective_from<=raw.sold_at AND (h.effective_to IS NULL OR raw.sold_at<h.effective_to)
 ORDER BY raw.source_hash,h.effective_from DESC,h.created_at DESC)
 SELECT seller.id,seller.tax_code,seller.name,raw.source_hash,raw.store_id,r.name,raw.device_name,raw.sold_at,raw.amount::numeric
 FROM raw_scope raw JOIN public.restaurants r ON r.id=raw.store_id AND r.brand_id='77000000-0000-0000-0000-000000000001'::uuid
 LEFT JOIN history h ON h.source_hash=raw.source_hash JOIN public.tax_entity seller ON seller.id=COALESCE(h.tax_entity_id,r.tax_entity_id)
 WHERE seller.id<>'8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid;
$$;
REVOKE ALL ON FUNCTION public.pos_photo_receipt_rows(date) FROM PUBLIC,anon,authenticated;
-- Preserve the legacy automation response while replacing its correlated history lookup.
DO $photo$ DECLARE d text; a integer;b integer; BEGIN
 SELECT pg_get_functiondef('public.get_photo_sales_misa_exports_by_tax_entity(date)'::regprocedure) INTO d;
 a:=strpos(d,'  WITH photo_rows AS (');b:=strpos(d,'  entity_rollups AS (');
 IF a=0 OR b<=a THEN RAISE EXCEPTION 'PHOTO_EXPORT_ANCHOR_CHANGED'; END IF;
 EXECUTE substr(d,1,a-1)||'  WITH photo_rows AS (SELECT * FROM public.pos_photo_receipt_rows(v_business_date)), '||substr(d,b);
END $photo$;
CREATE FUNCTION public.pos_daily_receipt_scope(p_business_date date) RETURNS TABLE(
 order_id uuid,store_id uuid,sold_at timestamptz,gross_sales numeric,tax_entity_id uuid,is_red_invoice boolean)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH candidates AS MATERIALIZED(SELECT DISTINCT order_id FROM public.payments WHERE is_revenue
 AND created_at>=p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND created_at<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'),
 paid AS MATERIALIZED(SELECT p.order_id,p.restaurant_id,max(p.created_at) sold_at,sum(COALESCE(p.amount_portion,p.amount)) gross
 FROM public.payments p JOIN candidates c ON c.order_id=p.order_id JOIN public.orders o ON o.id=p.order_id AND o.status='completed'
 JOIN public.restaurants r ON r.id=p.restaurant_id AND r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
 WHERE p.is_revenue AND r.id<>'3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid AND r.tax_entity_id IS DISTINCT FROM '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
 GROUP BY p.order_id,p.restaurant_id HAVING max(p.created_at)>=p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND max(p.created_at)<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'),
 historical AS MATERIALIZED(SELECT DISTINCT ON(p.order_id) p.order_id,h.tax_entity_id FROM paid p JOIN public.store_tax_entity_history h ON h.store_id=p.restaurant_id
 AND h.effective_from<=p.sold_at AND (h.effective_to IS NULL OR p.sold_at<h.effective_to) ORDER BY p.order_id,h.effective_from DESC,h.created_at DESC),
 jobs AS MATERIALIZED(SELECT DISTINCT ON(j.order_id) j.order_id,j.tax_entity_id FROM public.meinvoice_jobs j JOIN paid p ON p.order_id=j.order_id
 WHERE j.source_system='restaurant_pos' ORDER BY j.order_id,j.created_at DESC,j.id DESC)
 SELECT p.order_id,p.restaurant_id,p.sold_at,p.gross,COALESCE(j.tax_entity_id,h.tax_entity_id,r.tax_entity_id),i.id IS NOT NULL AND i.status<>'cancelled'
 FROM paid p JOIN public.restaurants r ON r.id=p.restaurant_id LEFT JOIN historical h ON h.order_id=p.order_id LEFT JOIN jobs j ON j.order_id=p.order_id
 LEFT JOIN public.red_invoice_intakes i ON i.order_id=p.order_id WHERE COALESCE(j.tax_entity_id,h.tax_entity_id,r.tax_entity_id)<>'8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid;
$$;
REVOKE ALL ON FUNCTION public.pos_daily_receipt_scope(date) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.get_pos_daily_sales_summary(p_business_date date) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF p_business_date IS NULL OR p_business_date<DATE '2020-01-01' OR p_business_date>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date THEN RAISE EXCEPTION 'SALES_REPORT_DATE_INVALID'; END IF;
 WITH paid AS MATERIALIZED(SELECT * FROM public.pos_daily_receipt_scope(p_business_date)),
 restaurant AS(SELECT tax_entity_id,count(*) receipt_count,count(*) FILTER(WHERE NOT is_red_invoice) general_count,
 count(*) FILTER(WHERE is_red_invoice) red_count,sum(gross_sales) gross FROM paid GROUP BY tax_entity_id),
 tax_totals AS(SELECT p.tax_entity_id,sum(item.total_amount_ex_tax) supply,sum(item.vat_amount) vat FROM paid p
 JOIN public.order_items item ON item.order_id=p.order_id AND item.status<>'cancelled' AND COALESCE(item.is_service_item,false)=false GROUP BY p.tax_entity_id),
 day_payments AS MATERIALIZED(SELECT p.* FROM public.payments p JOIN public.restaurants r ON r.id=p.restaurant_id
 WHERE p.is_revenue AND p.created_at>=p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND p.created_at<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 AND r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid AND r.id<>'3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid),
 payment_entities AS MATERIALIZED(SELECT DISTINCT ON(p.id) p.id,COALESCE(h.tax_entity_id,r.tax_entity_id) tax_entity_id
 FROM day_payments p JOIN public.restaurants r ON r.id=p.restaurant_id LEFT JOIN public.store_tax_entity_history h ON h.store_id=p.restaurant_id
 AND h.effective_from<=p.created_at AND (h.effective_to IS NULL OR p.created_at<h.effective_to) ORDER BY p.id,h.effective_from DESC,h.created_at DESC),
 cash AS(SELECT e.tax_entity_id,sum(COALESCE(p.amount_portion,p.amount)) FILTER(WHERE upper(p.method)='CASH') cash,
 sum(COALESCE(p.amount_portion,p.amount)) FILTER(WHERE upper(p.method)='BANKTRANSFER') bank FROM day_payments p JOIN payment_entities e ON e.id=p.id GROUP BY e.tax_entity_id),
 photo AS(SELECT tax_entity_id,count(*) receipt_count,sum(amount) gross,sum(round(amount/1.08)) supply,sum(amount-round(amount/1.08)) vat
 FROM public.pos_photo_receipt_rows(p_business_date) GROUP BY tax_entity_id),
 photo_status AS(SELECT r.tax_entity_id,count(DISTINCT r.id) store_count,count(DISTINCT run.store_id) imported
 FROM public.restaurants r LEFT JOIN public.photo_objet_sales_pull_runs run ON run.store_id=r.id AND run.target_date=p_business_date AND run.collector_method='excel' AND run.status='success'
 WHERE r.brand_id='77000000-0000-0000-0000-000000000001'::uuid AND r.is_active GROUP BY r.tax_entity_id),
 closing AS(SELECT r.tax_entity_id,count(*) FILTER(WHERE d.close_source='manual') closed,count(*) stores,
 sum(CASE WHEN d.close_source='manual' THEN d.counted_cash_amount-d.opening_cash_amount END) actual_deposit,
 sum(d.cash_variance) variance,sum(d.direct_order_cash_refunds) refunds,sum(d.delivery_cash_paid) cash_paid,sum(d.delivery_cash_recovered) recovered
 FROM public.restaurants r LEFT JOIN public.daily_closings d ON d.restaurant_id=r.id AND d.closing_date=p_business_date
 WHERE r.is_active AND r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
 AND r.id<>'3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid GROUP BY r.tax_entity_id),
 entities AS(SELECT tax_entity_id FROM restaurant UNION SELECT tax_entity_id FROM photo UNION SELECT tax_entity_id FROM photo_status UNION SELECT tax_entity_id FROM cash UNION SELECT tax_entity_id FROM closing)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('tax_entity_id',e.tax_entity_id,'seller_tax_code',t.tax_code,'seller_legal_name',t.name,
 'restaurant_receipt_count',COALESCE(r.receipt_count,0),'general_count',COALESCE(r.general_count,0),'red_count',COALESCE(r.red_count,0),
 'restaurant_gross',COALESCE(r.gross,0),'photo_receipt_count',COALESCE(p.receipt_count,0),'photo_gross',COALESCE(p.gross,0),
 'supply',COALESCE(tax.supply,0)+COALESCE(p.supply,0),'vat',COALESCE(tax.vat,0)+COALESCE(p.vat,0),
 'restaurant_cash',COALESCE(c.cash,0),'restaurant_bank_transfer',COALESCE(c.bank,0),
 'photo_complete',COALESCE(ps.imported=ps.store_count,true),'closing_complete',COALESCE(cl.closed=cl.stores,true),
 'closing_deposit',CASE WHEN cl.closed=cl.stores THEN cl.actual_deposit ELSE NULL END,
 'cash_variance',COALESCE(cl.variance,0),'cash_refunds',COALESCE(cl.refunds,0),'delivery_cash_paid',COALESCE(cl.cash_paid,0),'delivery_cash_recovered',COALESCE(cl.recovered,0),
 'bank',CASE WHEN a.id IS NULL THEN NULL ELSE jsonb_build_object('id',a.id,'bin',a.bank_bin,'label',a.bank_label,'account_number',a.account_number,'account_holder',a.account_holder) END)
 ORDER BY t.tax_code),'[]'::jsonb) INTO result FROM entities e JOIN public.tax_entity t ON t.id=e.tax_entity_id
 LEFT JOIN restaurant r ON r.tax_entity_id=e.tax_entity_id LEFT JOIN tax_totals tax ON tax.tax_entity_id=e.tax_entity_id LEFT JOIN photo p ON p.tax_entity_id=e.tax_entity_id
 LEFT JOIN cash c ON c.tax_entity_id=e.tax_entity_id LEFT JOIN photo_status ps ON ps.tax_entity_id=e.tax_entity_id LEFT JOIN closing cl ON cl.tax_entity_id=e.tax_entity_id
 LEFT JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=e.tax_entity_id AND a.retired_at IS NULL AND a.effective_from<=now()
 WHERE e.tax_entity_id<>'8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid;
 RETURN jsonb_build_object('business_date',p_business_date,'deposit_date',p_business_date+1,'as_of',statement_timestamp(),'entities',result);
END $$;
REVOKE ALL ON FUNCTION public.get_pos_daily_sales_summary(date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pos_daily_sales_summary(date) TO authenticated;

CREATE FUNCTION public.get_pos_daily_sales_export_page(p_business_date date,p_tax_entity_id uuid,p_source_system text,
 p_after_time timestamptz DEFAULT NULL,p_after_id text DEFAULT NULL,p_limit integer DEFAULT 100) RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;ids uuid[];
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF p_business_date IS NULL OR p_business_date<DATE '2020-01-01' OR p_business_date>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
 OR p_tax_entity_id IS NULL OR p_source_system NOT IN('restaurant_pos','photo_objet_moers') OR p_source_system IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
 OR (p_after_time IS NULL)<>(p_after_id IS NULL) THEN RAISE EXCEPTION 'SALES_EXPORT_PAGE_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM public.restaurant_daily_sales_finalizations WHERE business_date=p_business_date AND status<>'finalized') THEN RAISE EXCEPTION 'RESTAURANT_EXPORT_DATA_INTEGRITY_FAILED'; END IF;
 IF p_source_system='restaurant_pos' THEN
 SELECT array_agg(order_id ORDER BY sold_at,order_id) INTO ids FROM(SELECT order_id,sold_at FROM public.pos_daily_receipt_scope(p_business_date)
 WHERE tax_entity_id=p_tax_entity_id AND (p_after_time IS NULL OR (sold_at,order_id::text)>(p_after_time,p_after_id)) ORDER BY sold_at,order_id LIMIT p_limit) scope;
 SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.sold_at,r.receipt_id),'[]'::jsonb) INTO result
 FROM public.pos_restaurant_receipt_rows_v2(p_business_date,COALESCE(ids,'{}'::uuid[])) r WHERE r.tax_entity_id=p_tax_entity_id;
 ELSE
 SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.sold_at,r.source_hash),'[]'::jsonb) INTO result FROM(SELECT * FROM public.pos_photo_receipt_rows(p_business_date)
 WHERE tax_entity_id=p_tax_entity_id AND (p_after_time IS NULL OR (sold_at,source_hash)>(p_after_time,p_after_id)) ORDER BY sold_at,source_hash LIMIT p_limit) r;
 END IF;
 RETURN jsonb_build_object('business_date',p_business_date,'tax_entity_id',p_tax_entity_id,'source_system',p_source_system,'rows',result);
END $$;
REVOKE ALL ON FUNCTION public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer) TO authenticated;
DO $verify$ BEGIN
 IF has_function_privilege('anon','public.get_pos_daily_sales_summary(date)','EXECUTE') OR has_function_privilege('anon','public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)','EXECUTE') THEN RAISE EXCEPTION 'SALES_REPORT_SCOPE_DRIFT'; END IF;
END $verify$;
COMMIT;
