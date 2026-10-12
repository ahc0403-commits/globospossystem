BEGIN;
-- production-gate: self-verifying
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '120s';

-- Fingerprint v3 preserves the same source-field coverage without assembling
-- whole-day JSON arrays. Only per-row digests are aggregated; buyer data remains
-- internal. Summary and export pages switch together, without rewriting sales.
CREATE OR REPLACE FUNCTION public.pos_sales_export_source_revisions_v3(p_business_date date,p_tax_entity_id uuid)
RETURNS TABLE(tax_entity_id uuid,source_revision text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
WITH scope AS MATERIALIZED (
 SELECT * FROM public.pos_daily_receipt_scope(p_business_date) WHERE p_tax_entity_id IS NULL
 UNION ALL SELECT * FROM public.pos_daily_receipt_scope_page(p_business_date,p_tax_entity_id,NULL,NULL,2147483647) WHERE p_tax_entity_id IS NOT NULL),
photo_scope AS MATERIALIZED (
 SELECT * FROM public.pos_photo_receipt_rows(p_business_date) WHERE p_tax_entity_id IS NULL
 UNION ALL SELECT * FROM public.pos_photo_receipt_rows_page(p_business_date,p_tax_entity_id,NULL,NULL,2147483647) WHERE p_tax_entity_id IS NOT NULL),
scope_json AS (SELECT tax_entity_id,md5(string_agg(md5(to_jsonb(s)::text),'' ORDER BY order_id)) j FROM scope s GROUP BY tax_entity_id),
items AS (SELECT s.tax_entity_id,item.order_id,item.id,item.menu_item_id,item.item_type,item.status,item.is_service_item,item.quantity,item.unit_price,item.total_amount_ex_tax,item.vat_rate,item.vat_amount,item.vat_breakdown,item.paying_amount_inc_tax FROM public.order_items item JOIN scope s ON s.order_id=item.order_id),
item_json AS (SELECT tax_entity_id,md5(string_agg(md5((to_jsonb(i)-'tax_entity_id')::text),'' ORDER BY order_id,id)) j FROM items i GROUP BY tax_entity_id),
payments AS (SELECT s.tax_entity_id,p.order_id,p.id,p.method,p.amount,p.amount_portion,p.created_at,p.is_revenue FROM public.payments p JOIN scope s ON s.order_id=p.order_id),
payment_json AS (SELECT tax_entity_id,md5(string_agg(md5((to_jsonb(p)-'tax_entity_id')::text),'' ORDER BY order_id,id)) j FROM payments p GROUP BY tax_entity_id),
jobs AS (SELECT s.tax_entity_id,j.order_id,j.id,j.snapshot_version,j.line_items_snapshot,j.buyer_snapshot,j.payment_method_snapshot,j.payment_summary,j.status,j.misa_ref_id,j.invoice_number,j.dispatch_claim_id,j.dispatch_attempts FROM public.meinvoice_jobs j JOIN scope s ON s.order_id=j.order_id WHERE j.source_system='restaurant_pos'),
job_json AS (SELECT tax_entity_id,md5(string_agg(md5((to_jsonb(j)-'tax_entity_id')::text),'' ORDER BY order_id,id)) j FROM jobs j GROUP BY tax_entity_id),
contact_json AS (SELECT s.tax_entity_id,md5(string_agg(md5(to_jsonb(i)::text),'' ORDER BY i.order_id)) j FROM public.red_invoice_intakes i JOIN scope s ON s.order_id=i.order_id GROUP BY s.tax_entity_id),
photo_json AS (SELECT tax_entity_id,md5(string_agg(md5(to_jsonb(p)::text),'' ORDER BY sold_at,source_hash)) j FROM photo_scope p GROUP BY tax_entity_id),
entities AS (SELECT tax_entity_id FROM scope UNION SELECT tax_entity_id FROM photo_scope)
SELECT e.tax_entity_id,md5(jsonb_build_object('version',3,'scope',s.j,'items',i.j,'payments',p.j,'jobs',j.j,'contacts',c.j,'photo',ph.j)::text)
FROM entities e LEFT JOIN scope_json s USING(tax_entity_id) LEFT JOIN item_json i USING(tax_entity_id)
LEFT JOIN payment_json p USING(tax_entity_id) LEFT JOIN job_json j USING(tax_entity_id)
LEFT JOIN contact_json c USING(tax_entity_id) LEFT JOIN photo_json ph USING(tax_entity_id);
$$;
REVOKE ALL ON FUNCTION public.pos_sales_export_source_revisions_v3(date,uuid) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.pos_sales_export_source_revisions(p_business_date date)
RETURNS TABLE(tax_entity_id uuid,source_revision text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT * FROM public.pos_sales_export_source_revisions_v3(p_business_date,NULL);
$$;
REVOKE ALL ON FUNCTION public.pos_sales_export_source_revisions(date) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.pos_sales_export_source_revision(p_business_date date,p_tax_entity_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT COALESCE((SELECT source_revision FROM public.pos_sales_export_source_revisions_v3(p_business_date,p_tax_entity_id)),
 md5(jsonb_build_object('version',3,'scope',NULL::jsonb,'items',NULL::jsonb,'payments',NULL::jsonb,'jobs',NULL::jsonb,'contacts',NULL::jsonb,'photo',NULL::jsonb)::text));
$$;
REVOKE ALL ON FUNCTION public.pos_sales_export_source_revision(date,uuid) FROM PUBLIC,anon,authenticated;


DO $summary$
DECLARE d text; item_filter text; source_count text; export_count text;
BEGIN
 SELECT pg_get_functiondef('public.get_pos_daily_sales_summary(date)'::regprocedure) INTO d;
 IF strpos(d,'''bunsik_store_count''')>0 THEN RETURN; END IF;
 IF strpos(d,'public.pos_sales_export_source_revision(p_business_date,e.tax_entity_id)')=0
 OR strpos(d,'sum(item.vat_amount) vat FROM paid p')=0
 OR strpos(d,' entities AS(')=0 THEN RAISE EXCEPTION 'DEPOSIT_SUMMARY_ANCHOR_CHANGED'; END IF;
 -- Delivery-fee removal may already be deployed despite its later timestamp.
 -- Replace the exact reviewed predicate, keeping it on the shared aggregate.
 item_filter:='item.status<>''cancelled'' AND COALESCE(item.is_service_item,false)=false';
 IF strpos(d,'public.pos_is_delivery_fee_item(')>0 THEN
  item_filter:=item_filter||' AND (p_business_date<DATE ''2026-10-12'' OR NOT public.pos_is_delivery_fee_item(item.item_type,item.menu_item_id,item.display_name,item.label))';
 END IF;
 source_count:='(SELECT count(*) FROM public.order_items item JOIN paid scope ON scope.order_id=item.order_id WHERE scope.tax_entity_id=e.tax_entity_id AND '||item_filter||')';
 export_count:='(SELECT COALESCE(sum(CASE WHEN item.vat_rate=-1 THEN jsonb_array_length(item.vat_breakdown) ELSE 1 END),0) FROM public.order_items item JOIN paid scope ON scope.order_id=item.order_id WHERE scope.tax_entity_id=e.tax_entity_id AND '||item_filter||')';
 IF strpos(d,source_count)=0 OR strpos(d,export_count)=0 THEN
  RAISE EXCEPTION 'DEPOSIT_ITEM_COUNT_ANCHOR_CHANGED';
 END IF;
 d:=replace(d,'WITH paid AS MATERIALIZED',
 'WITH revisions AS MATERIALIZED(SELECT * FROM public.pos_sales_export_source_revisions(p_business_date)),
 protections AS(SELECT tax_entity_id,true present FROM public.sales_external_reporting_protections WHERE business_date=p_business_date GROUP BY tax_entity_id),
 paid AS MATERIALIZED');
 d:=replace(d,'sum(item.vat_amount) vat FROM paid p',
 'sum(item.vat_amount) vat,count(*) source_item_count,sum(CASE WHEN item.vat_rate=-1 THEN jsonb_array_length(item.vat_breakdown) ELSE 1 END) export_line_count FROM paid p');
 d:=replace(d,'public.pos_sales_export_source_revision(p_business_date,e.tax_entity_id)',
 'COALESCE(rev.source_revision,md5(jsonb_build_object(''version'',3,''scope'',NULL::jsonb,''items'',NULL::jsonb,''payments'',NULL::jsonb,''jobs'',NULL::jsonb,''contacts'',NULL::jsonb,''photo'',NULL::jsonb)::text))');
 d:=replace(d,'COALESCE((SELECT revision FROM public.sales_invoice_mapping_revisions WHERE tax_entity_id=e.tax_entity_id),0)','COALESCE(mapping.revision,0)');
 d:=replace(d,'EXISTS(SELECT 1 FROM public.sales_external_reporting_protections x WHERE x.business_date=p_business_date AND x.tax_entity_id=e.tax_entity_id)','COALESCE(protection.present,false)');
 d:=replace(d,source_count,'COALESCE(tax.source_item_count,0)');
 d:=replace(d,export_count,'COALESCE(tax.export_line_count,0)');
 d:=replace(d,' entities AS(', $ctes$
 bunsik_scope AS MATERIALIZED(SELECT id,name,tax_entity_id FROM public.restaurants
 WHERE is_active AND brand_id='a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878'::uuid
 AND id<>'3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
 AND tax_entity_id IS DISTINCT FROM '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid),
 bunsik_cash AS(SELECT p.restaurant_id,sum(COALESCE(p.amount_portion,p.amount)) cash,sum(COALESCE(p.amount_portion,p.amount)) all_payments
 FROM day_payments p JOIN bunsik_scope s ON s.id=p.restaurant_id GROUP BY p.restaurant_id),
 bunsik_cash_only AS(SELECT p.restaurant_id,sum(COALESCE(p.amount_portion,p.amount)) cash
 FROM day_payments p JOIN bunsik_scope s ON s.id=p.restaurant_id WHERE upper(p.method)='CASH' GROUP BY p.restaurant_id),
 movements AS(SELECT m.restaurant_id,sum(amount) FILTER(WHERE kind='payout') paid,sum(amount) FILTER(WHERE kind='recovery' AND method='CASH') recovered
 FROM public.direct_order_driver_cash_movements m JOIN bunsik_scope s ON s.id=m.restaurant_id
 WHERE occurred_at>=p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND occurred_at<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' GROUP BY m.restaurant_id),
 refund_rows AS(SELECT DISTINCT x.id,x.restaurant_id,x.amount FROM public.direct_order_refund_records x
 JOIN bunsik_scope s ON s.id=x.restaurant_id JOIN public.direct_order_refund_evidence evidence ON evidence.refund_id=x.id AND evidence.method='CASH'
 WHERE x.recorded_at>=p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND x.recorded_at<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'),
 refunds AS(SELECT restaurant_id,sum(amount) amount FROM refund_rows GROUP BY restaurant_id),
 bunsik AS(SELECT s.tax_entity_id,count(*) store_count,count(*) FILTER(WHERE dc.close_source='manual') closed_count,
 sum(dc.counted_cash_amount-dc.opening_cash_amount) FILTER(WHERE dc.close_source='manual') closed_deposit,
 count(*) FILTER(WHERE dc.close_source='manual' AND dc.counted_cash_amount<dc.opening_cash_amount) shortfall_count,
 count(*) FILTER(WHERE dc.close_source='manual' AND dc.cash_variance<>0) variance_count,
 count(*) FILTER(WHERE dc.close_source='manual' AND (dc.payments_total IS DISTINCT FROM COALESCE(all_cash.all_payments,0)
 OR dc.payments_cash IS DISTINCT FROM COALESCE(c.cash,0) OR dc.direct_order_cash_refunds IS DISTINCT FROM COALESCE(f.amount,0)
 OR dc.delivery_cash_paid IS DISTINCT FROM COALESCE(m.paid,0) OR dc.delivery_cash_recovered IS DISTINCT FROM COALESCE(m.recovered,0))) late_ledger_count,
 COALESCE(sum(dc.cash_variance) FILTER(WHERE dc.close_source='manual'),0) variance,
 sum(COALESCE(c.cash,0)) cash,sum(COALESCE(c.cash,0)-COALESCE(m.paid,0)+COALESCE(m.recovered,0)-COALESCE(f.amount,0)) expected_deposit,
 jsonb_agg(jsonb_build_object('store_id',s.id,'store_name',s.name) ORDER BY s.name,s.id) stores
 FROM bunsik_scope s LEFT JOIN public.daily_closings dc ON dc.restaurant_id=s.id AND dc.closing_date=p_business_date
 LEFT JOIN bunsik_cash all_cash ON all_cash.restaurant_id=s.id LEFT JOIN bunsik_cash_only c ON c.restaurant_id=s.id
 LEFT JOIN movements m ON m.restaurant_id=s.id LEFT JOIN refunds f ON f.restaurant_id=s.id GROUP BY s.tax_entity_id),
 entities AS($ctes$);
 d:=replace(d,'''restaurant_bank_transfer'',COALESCE(c.bank,0),',
 '''restaurant_bank_transfer'',COALESCE(c.bank,0),''source_revision_version'',3,
 ''missing_photo_store_count'',COALESCE(ps.store_count-ps.imported,0),
 ''bunsik_store_count'',COALESCE(bu.store_count,0),''bunsik_closed_store_count'',COALESCE(bu.closed_count,0),
 ''bunsik_closed_deposit'',CASE WHEN COALESCE(bu.store_count,0)=0 THEN 0 ELSE bu.closed_deposit END,
 ''bunsik_shortfall_store_count'',COALESCE(bu.shortfall_count,0),''bunsik_variance_store_count'',COALESCE(bu.variance_count,0),
 ''bunsik_late_ledger_store_count'',COALESCE(bu.late_ledger_count,0),''bunsik_variance'',COALESCE(bu.variance,0),
 ''bunsik_cash'',COALESCE(bu.cash,0),''bunsik_expected_deposit'',COALESCE(bu.expected_deposit,0),''bunsik_stores'',COALESCE(bu.stores,''[]''::jsonb),');
 d:=replace(d,'LEFT JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=e.tax_entity_id',
 'LEFT JOIN revisions rev ON rev.tax_entity_id=e.tax_entity_id LEFT JOIN public.sales_invoice_mapping_revisions mapping ON mapping.tax_entity_id=e.tax_entity_id
 LEFT JOIN protections protection ON protection.tax_entity_id=e.tax_entity_id LEFT JOIN bunsik bu ON bu.tax_entity_id=e.tax_entity_id
 LEFT JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=e.tax_entity_id');
 EXECUTE d;
END $summary$;

-- Routine 30-second refreshes need the financial aggregates, not an export
-- fingerprint over every item, invoice job and buyer. Keep the one-date API
-- intact; the explicitly named overload defers that work until export is used.
DO $deferred_summary$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.get_pos_daily_sales_summary(date)'::regprocedure) INTO d;
 IF strpos(d,'revisions AS MATERIALIZED(SELECT * FROM public.pos_sales_export_source_revisions(p_business_date))')=0 THEN
  RAISE EXCEPTION 'DEPOSIT_DEFERRED_SUMMARY_ANCHOR_CHANGED'; END IF;
 d:=replace(d,'get_pos_daily_sales_summary(p_business_date date)',
 'get_pos_daily_sales_summary(p_business_date date, p_include_export_metadata boolean)');
 d:=replace(d,E'BEGIN\n IF auth.uid()',E'BEGIN\n IF p_include_export_metadata IS NULL THEN RAISE EXCEPTION ''SALES_REPORT_METADATA_INVALID''; END IF;\n IF auth.uid()');
 d:=replace(d,'SELECT * FROM public.pos_sales_export_source_revisions(p_business_date)',
 'SELECT * FROM public.pos_sales_export_source_revisions(p_business_date) WHERE p_include_export_metadata');
 d:=replace(d,'''source_revision'',COALESCE(rev.source_revision,',
 '''export_metadata_deferred'',NOT p_include_export_metadata,''source_revision'',CASE WHEN p_include_export_metadata THEN COALESCE(rev.source_revision,');
 d:=replace(d,'''photo'',NULL::jsonb)::text)),', '''photo'',NULL::jsonb)::text)) ELSE NULL END,');
 IF strpos(d,'''export_metadata_deferred''')=0 OR strpos(d,'ELSE NULL END,')=0 THEN
  RAISE EXCEPTION 'DEPOSIT_DEFERRED_REVISION_ANCHOR_CHANGED'; END IF;
 EXECUTE d;
END $deferred_summary$;
REVOKE ALL ON FUNCTION public.get_pos_daily_sales_summary(date,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pos_daily_sales_summary(date,boolean) TO authenticated;

DO $page_version$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)'::regprocedure) INTO d;
 IF strpos(d,'''source_revision_version''')=0 THEN
  IF strpos(d,'''source_revision'',public.pos_sales_export_source_revision(')=0 THEN RAISE EXCEPTION 'DEPOSIT_PAGE_REVISION_ANCHOR_CHANGED'; END IF;
  d:=replace(d,'''source_revision'',public.pos_sales_export_source_revision(','''source_revision_version'',3,''source_revision'',public.pos_sales_export_source_revision(');
  EXECUTE d;
 END IF;
END $page_version$;

-- Keep the original closing-history interface for other consumers. The new
-- private reader accepts one exact day without reading years of history.
DO $history$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.get_daily_closing_days(uuid,integer)'::regprocedure) INTO d;
 IF strpos(d,'p_limit integer DEFAULT 30)')=0 OR strpos(d,'::date - day_offset')=0 THEN
  RAISE EXCEPTION 'DEPOSIT_CLOSING_HISTORY_ANCHOR_CHANGED'; END IF;
 d:=replace(d,'public.get_daily_closing_days(', 'public.get_daily_closing_days_for_deposit(');
 d:=replace(d,'p_limit integer DEFAULT 30)', 'p_limit integer DEFAULT 30, p_closing_date date DEFAULT NULL)');
 d:=replace(d,'(now() AT TIME ZONE ''Asia/Ho_Chi_Minh'')::date', 'COALESCE(p_closing_date,(now() AT TIME ZONE ''Asia/Ho_Chi_Minh'')::date)');
 d:=replace(d,E'BEGIN\n  PERFORM',E'BEGIN\n  IF p_closing_date IS NOT NULL THEN\n    IF p_closing_date<DATE ''2020-01-01'' OR p_closing_date>(now() AT TIME ZONE ''Asia/Ho_Chi_Minh'')::date THEN RAISE EXCEPTION ''DAILY_CLOSING_DATE_INVALID''; END IF;\n    v_limit:=1;\n  END IF;\n  PERFORM');
 EXECUTE d;
END $history$;
REVOKE ALL ON FUNCTION public.get_daily_closing_days_for_deposit(uuid,integer,date) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.get_daily_closing_deposit_days(p_store_id uuid,p_limit integer DEFAULT 30,p_closing_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;bank jsonb;last_day date;first_day date;
BEGIN
 PERFORM public.require_pos_admin_actor_for_store(p_store_id,'DAILY_CLOSINGS_FORBIDDEN');
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 90 THEN RAISE EXCEPTION 'DAILY_CLOSING_DATE_INVALID'; END IF;
 last_day:=COALESCE(p_closing_date,(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date);
 first_day:=last_day-CASE WHEN p_closing_date IS NULL THEN p_limit-1 ELSE 0 END;
 SELECT jsonb_build_object('id',a.id,'bin',a.bank_bin,'label',a.bank_label,'account_number',a.account_number,'account_holder',a.account_holder)
 INTO bank FROM public.restaurants r JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=r.tax_entity_id
 WHERE r.id=p_store_id AND a.retired_at IS NULL AND a.effective_from<=now();
 WITH refund_rows AS(SELECT DISTINCT x.id,x.amount,(x.recorded_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS day
 FROM public.direct_order_refund_records x JOIN public.direct_order_refund_evidence e ON e.refund_id=x.id
 WHERE x.restaurant_id=p_store_id AND e.method='CASH'
 AND x.recorded_at>=first_day::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND x.recorded_at<(last_day+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'),
 refunds AS(SELECT day,sum(amount) amount FROM refund_rows GROUP BY day),
 movements AS(SELECT (occurred_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS day,
 COALESCE(sum(amount) FILTER(WHERE kind='payout'),0) paid,COALESCE(sum(amount) FILTER(WHERE kind='recovery' AND method='CASH'),0) recovered
 FROM public.direct_order_driver_cash_movements WHERE restaurant_id=p_store_id
 AND occurred_at>=first_day::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND occurred_at<(last_day+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' GROUP BY 1),
 days AS(SELECT d.closing_date,to_jsonb(d) row FROM public.get_daily_closing_days_for_deposit(p_store_id,p_limit,p_closing_date) d)
 SELECT COALESCE(jsonb_agg(d.row||CASE WHEN d.row->>'close_source'='manual' THEN '{}'::jsonb ELSE
 jsonb_build_object('direct_order_cash_refunds',COALESCE(f.amount,0),'delivery_cash_paid',COALESCE(m.paid,0),'delivery_cash_recovered',COALESCE(m.recovered,0),
 'expected_cash_amount',COALESCE((d.row->>'opening_cash_amount')::numeric,5000000)+COALESCE((d.row->>'payments_cash')::numeric,0)-COALESCE(f.amount,0)-COALESCE(m.paid,0)+COALESCE(m.recovered,0)) END
 ||jsonb_build_object('bank',bank,'deposit_date',d.closing_date+1,
 'cash_ledger_changed',d.row->>'close_source'='manual' AND (
 (d.row->>'ledger_payments_cash')::numeric IS DISTINCT FROM (d.row->>'payments_cash')::numeric
 OR (d.row->>'direct_order_cash_refunds')::numeric IS DISTINCT FROM COALESCE(f.amount,0)
 OR (d.row->>'delivery_cash_paid')::numeric IS DISTINCT FROM COALESCE(m.paid,0)
 OR (d.row->>'delivery_cash_recovered')::numeric IS DISTINCT FROM COALESCE(m.recovered,0))) ORDER BY d.closing_date DESC),'[]'::jsonb)
 INTO result FROM days d LEFT JOIN refunds f ON f.day=d.closing_date LEFT JOIN movements m ON m.day=d.closing_date;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_daily_closing_deposit_days(uuid,integer,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_daily_closing_deposit_days(uuid,integer,date) TO authenticated;

-- Current endpoints already authorize the store and hold the same closing
-- advisory lock. Correct the final reconciliation without rewriting old rows.
CREATE OR REPLACE FUNCTION public.get_daily_closing_cash_preview(p_store_id uuid,p_closing_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b jsonb;day date;started timestamptz;finished timestamptz;refunds numeric;paid numeric;recovered numeric;bank jsonb;
BEGIN
 b:=public.get_daily_closing_cash_before_reconciliation(p_store_id,p_closing_date);
 day:=(b->>'closing_date')::date;started:=day::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';finished:=(day+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
 SELECT COALESCE(sum(f.amount),0) INTO refunds FROM(SELECT DISTINCT x.id,x.amount FROM public.direct_order_refund_records x JOIN public.direct_order_refund_evidence e ON e.refund_id=x.id
 WHERE x.restaurant_id=p_store_id AND e.method='CASH' AND x.recorded_at>=started AND x.recorded_at<finished) f;
 SELECT COALESCE(sum(amount) FILTER(WHERE kind='payout'),0),COALESCE(sum(amount) FILTER(WHERE kind='recovery' AND method='CASH'),0)
 INTO paid,recovered FROM public.direct_order_driver_cash_movements WHERE restaurant_id=p_store_id AND occurred_at>=started AND occurred_at<finished;
 SELECT jsonb_build_object('id',a.id,'bin',a.bank_bin,'label',a.bank_label,'account_number',a.account_number,'account_holder',a.account_holder)
 INTO bank FROM public.restaurants r JOIN public.tax_entity_collection_accounts a ON a.tax_entity_id=r.tax_entity_id
 WHERE r.id=p_store_id AND a.retired_at IS NULL AND a.effective_from<=now();
 RETURN b||jsonb_build_object('delivery_cash_paid',paid,'delivery_cash_recovered',recovered,'direct_order_cash_refunds',refunds,
 'expected_cash_amount',(b->>'opening_cash_amount')::numeric+(b->>'payments_cash')::numeric-paid+recovered-refunds,
 'deposit_date',day+1,'bank',bank);
END $$;

CREATE OR REPLACE FUNCTION public.create_daily_closing(p_store_id uuid,p_notes text DEFAULT NULL,p_cash_denominations jsonb DEFAULT '{}',p_opening_cash_amount numeric DEFAULT 5000000,p_closing_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b jsonb;day date;started timestamptz;finished timestamptz;refunds numeric;paid numeric;recovered numeric;updated jsonb;
BEGIN
 day:=COALESCE(p_closing_date,(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date);
 PERFORM pg_advisory_xact_lock(hashtextextended('direct-order-cash-day:'||p_store_id::text||':'||day::text,0));
 b:=public.create_daily_closing_before_reconciliation(p_store_id,p_notes,p_cash_denominations,p_opening_cash_amount,p_closing_date);
 started:=day::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';finished:=(day+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
 SELECT COALESCE(sum(f.amount),0) INTO refunds FROM(SELECT DISTINCT x.id,x.amount FROM public.direct_order_refund_records x JOIN public.direct_order_refund_evidence e ON e.refund_id=x.id
 WHERE x.restaurant_id=p_store_id AND e.method='CASH' AND x.recorded_at>=started AND x.recorded_at<finished) f;
 SELECT COALESCE(sum(amount) FILTER(WHERE kind='payout'),0),COALESCE(sum(amount) FILTER(WHERE kind='recovery' AND method='CASH'),0)
 INTO paid,recovered FROM public.direct_order_driver_cash_movements WHERE restaurant_id=p_store_id AND occurred_at>=started AND occurred_at<finished;
 UPDATE public.daily_closings d SET delivery_cash_paid=paid,delivery_cash_recovered=recovered,direct_order_cash_refunds=refunds,
 expected_cash_amount=d.opening_cash_amount+d.payments_cash-paid+recovered-refunds,
 cash_variance=d.counted_cash_amount-(d.opening_cash_amount+d.payments_cash-paid+recovered-refunds)
 WHERE d.restaurant_id=p_store_id AND d.closing_date=day
 RETURNING jsonb_build_object('expected_cash_amount',d.expected_cash_amount,'cash_variance',d.cash_variance,'deposit_date',day+1,'deposit_amount',d.counted_cash_amount-d.opening_cash_amount,
 'direct_order_cash_refunds',refunds,'delivery_cash_paid',paid,'delivery_cash_recovered',recovered) INTO updated;
 RETURN b||updated;
END $$;

CREATE OR REPLACE FUNCTION public.get_bank_transfer_sales_page(
 p_from_date date,p_to_date date,p_tax_entity_id uuid DEFAULT NULL,p_store_id uuid DEFAULT NULL,
 p_after_time timestamptz DEFAULT NULL,p_after_id uuid DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 IF auth.uid() IS NULL OR (p_tax_entity_id IS NULL AND p_store_id IS NULL) THEN RAISE EXCEPTION 'BANK_TRANSFER_FORBIDDEN'; END IF;
 IF NOT public.is_super_admin() THEN
  IF p_store_id IS NULL THEN RAISE EXCEPTION 'BANK_TRANSFER_FORBIDDEN'; END IF;
  PERFORM public.require_pos_admin_actor_for_store(p_store_id,'BANK_TRANSFER_FORBIDDEN');
 END IF;
 IF p_from_date IS NULL OR p_to_date IS NULL OR p_from_date<DATE '2020-01-01' OR p_to_date<p_from_date
 OR p_to_date>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR p_to_date-p_from_date>366
 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR (p_after_time IS NULL)<>(p_after_id IS NULL) THEN RAISE EXCEPTION 'BANK_TRANSFER_PAGE_INVALID'; END IF;
 WITH day_payments AS MATERIALIZED(
 SELECT p.id payment_id,p.order_id,p.restaurant_id store_id,r.name store_name,r.tax_entity_id,
 p.created_at,COALESCE(p.amount_portion,p.amount) amount
 FROM public.payments p JOIN public.restaurants r ON r.id=p.restaurant_id
 WHERE p.is_revenue AND upper(p.method)='BANKTRANSFER'
 AND (p_store_id IS NULL OR p.restaurant_id=p_store_id)
 AND r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
 AND r.id<>'3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
 AND p.created_at>=p_from_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 AND p.created_at<(p_to_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 AND (p_after_time IS NULL OR (p.created_at,p.id)>(p_after_time,p_after_id))
 AND (p_tax_entity_id IS NULL OR r.tax_entity_id=p_tax_entity_id OR r.id IN(
   SELECT h.store_id FROM public.store_tax_entity_history h WHERE h.tax_entity_id=p_tax_entity_id
   AND h.effective_from<(p_to_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
   AND (h.effective_to IS NULL OR h.effective_to>p_from_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')))),
 ownership AS(SELECT DISTINCT ON(p.payment_id) p.*,COALESCE(h.tax_entity_id,p.tax_entity_id) seller_id
 FROM day_payments p LEFT JOIN public.store_tax_entity_history h ON h.store_id=p.store_id
 AND h.effective_from<=p.created_at AND (h.effective_to IS NULL OR p.created_at<h.effective_to)
 ORDER BY p.payment_id,h.effective_from DESC,h.created_at DESC),
 candidates AS MATERIALIZED(SELECT * FROM ownership WHERE (p_tax_entity_id IS NULL OR seller_id=p_tax_entity_id)
 AND seller_id IS DISTINCT FROM '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
 ORDER BY created_at,payment_id LIMIT p_limit+1),
 receipt_orders AS(SELECT DISTINCT order_id FROM candidates),
 receipts AS(SELECT DISTINCT ON(r.order_id) r.order_id,r.receipt_number FROM public.digital_receipts r
 JOIN receipt_orders o ON o.order_id=r.order_id ORDER BY r.order_id,r.created_at DESC,r.id DESC),
 page AS(SELECT c.payment_id,c.order_id,c.store_id,c.store_name,c.created_at,c.amount,r.receipt_number
 FROM candidates c LEFT JOIN receipts r ON r.order_id=c.order_id ORDER BY c.created_at,c.payment_id LIMIT p_limit)
 SELECT jsonb_build_object('from_date',p_from_date,'to_date',p_to_date,'tax_entity_id',p_tax_entity_id,'store_id',p_store_id,
 'has_more',(SELECT count(*)>p_limit FROM candidates),'rows',COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY created_at,payment_id) FROM page p),'[]'::jsonb)) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_bank_transfer_sales_page(date,date,uuid,uuid,timestamptz,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_bank_transfer_sales_page(date,date,uuid,uuid,timestamptz,uuid,integer) TO authenticated;
CREATE INDEX IF NOT EXISTS payments_bank_transfer_page ON public.payments(restaurant_id,created_at,id) WHERE is_revenue AND upper(method)='BANKTRANSFER';

DO $verify$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.get_pos_daily_sales_summary(date)'::regprocedure) INTO d;
 IF strpos(d,'''bunsik_store_count''')=0 OR strpos(d,'public.pos_sales_export_source_revision(p_business_date,e.tax_entity_id)')>0
 OR strpos(d,'WHERE scope.tax_entity_id=e.tax_entity_id')>0
 OR strpos(pg_get_functiondef('public.get_daily_closing_days_for_deposit(uuid,integer,date)'::regprocedure),'v_limit:=1')=0
 OR has_function_privilege('anon','public.get_daily_closing_deposit_days(uuid,integer,date)','EXECUTE')
 OR has_function_privilege('anon','public.get_bank_transfer_sales_page(date,date,uuid,uuid,timestamptz,uuid,integer)','EXECUTE')
 OR has_function_privilege('anon','public.pos_sales_export_source_revisions(date)','EXECUTE')
 OR has_function_privilege('anon','public.get_pos_daily_sales_summary(date,boolean)','EXECUTE') THEN RAISE EXCEPTION 'DEPOSIT_BREAKDOWN_CONTRACT_DRIFT'; END IF;
END $verify$;
COMMIT;
