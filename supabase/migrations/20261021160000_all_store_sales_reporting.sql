-- Automatically include every registered restaurant brand in sales reporting.
-- Keep the legacy bunsik_* response keys for already deployed clients; their
-- meaning is now all fiscal restaurants. Workbook/issued snapshots are unchanged.
BEGIN;
-- production-gate: self-verifying
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='120s';
DO $patch$
DECLARE signature text; d text; a integer; b integer;
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.get_pos_daily_sales_summary(date)','public.get_pos_daily_sales_summary(date,boolean)'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  IF strpos(d,'''restaurant_stores''')>0 THEN CONTINUE; END IF;
  a:=strpos(d,' bunsik_scope AS MATERIALIZED(');b:=strpos(d,' bunsik_cash AS(');
  IF a=0 OR b<=a OR strpos(d,'LEFT JOIN bunsik bu ON bu.tax_entity_id=e.tax_entity_id')=0 THEN
   RAISE EXCEPTION 'ALL_STORE_SALES_SUMMARY_ANCHOR_CHANGED'; END IF;
  d:=substr(d,1,a-1)||$ctes$
 store_receipts AS(SELECT store_id,tax_entity_id,count(*) receipt_count,sum(gross_sales) gross
 FROM paid GROUP BY store_id,tax_entity_id),
 store_payments AS(SELECT p.restaurant_id store_id,e.tax_entity_id,
 sum(COALESCE(p.amount_portion,p.amount)) FILTER(WHERE upper(p.method)='CASH') cash,
 sum(COALESCE(p.amount_portion,p.amount)) FILTER(WHERE upper(p.method)='BANKTRANSFER') bank,
 sum(COALESCE(p.amount_portion,p.amount)) FILTER(WHERE upper(p.method) NOT IN('CASH','BANKTRANSFER')) other
 FROM day_payments p JOIN payment_entities e ON e.id=p.id GROUP BY p.restaurant_id,e.tax_entity_id),
 store_lines AS MATERIALIZED(SELECT item.id,item.menu_item_id,item.item_type,item.total_amount_ex_tax,item.vat_amount,
 p.store_id,p.tax_entity_id,p.sold_at FROM paid p JOIN public.order_items item ON item.order_id=p.order_id
 WHERE item.status<>'cancelled' AND COALESCE(item.is_service_item,false)=false
 AND (p_business_date<DATE '2026-10-12' OR NOT public.pos_is_delivery_fee_item(item.item_type,item.menu_item_id,item.display_name,item.label))),
 store_profiles AS MATERIALIZED(SELECT DISTINCT ON(l.id) l.id,profile.id profile_id
 FROM store_lines l JOIN public.invoice_approved_profiles profile ON profile.store_id=l.store_id AND profile.tax_entity_id=l.tax_entity_id
 AND ((profile.approval_type='menu_item' AND profile.menu_item_id=l.menu_item_id)
 OR (profile.approval_type='item_type' AND profile.item_type=l.item_type AND l.menu_item_id IS NULL))
 AND profile.effective_from<=l.sold_at AND (profile.effective_to IS NULL OR l.sold_at<profile.effective_to)
 ORDER BY l.id,profile.effective_from DESC,profile.id DESC),
 store_tax AS(SELECT l.store_id,l.tax_entity_id,sum(l.total_amount_ex_tax) supply,sum(l.vat_amount) vat,
 count(*) FILTER(WHERE profile.profile_id IS NULL) missing_mapping_count
 FROM store_lines l LEFT JOIN store_profiles profile ON profile.id=l.id GROUP BY l.store_id,l.tax_entity_id),
 registry_sellers AS MATERIALIZED(SELECT DISTINCT ON(r.id) r.id,r.name,r.brand_id,r.is_active,r.created_at,
 COALESCE(h.tax_entity_id,r.tax_entity_id) tax_entity_id FROM public.restaurants r
 LEFT JOIN public.store_tax_entity_history h ON h.store_id=r.id
 AND h.effective_from<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 AND (h.effective_to IS NULL OR h.effective_to>p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
 ORDER BY r.id,h.effective_from DESC,h.created_at DESC),
 store_activity AS MATERIALIZED(SELECT m.restaurant_id store_id FROM public.direct_order_driver_cash_movements m
 WHERE m.occurred_at>=p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 AND m.occurred_at<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 AND (m.kind='payout' OR (m.kind='recovery' AND m.method='CASH'))
 UNION SELECT x.restaurant_id FROM public.direct_order_refund_records x
 JOIN public.direct_order_refund_evidence evidence ON evidence.refund_id=x.id AND evidence.method='CASH'
 WHERE x.recorded_at>=p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 AND x.recorded_at<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 UNION SELECT d.restaurant_id FROM public.daily_closings d WHERE d.closing_date=p_business_date),
 report_store_scope AS(SELECT r.id store_id,r.name store_name,r.tax_entity_id FROM registry_sellers r
 WHERE r.is_active AND r.created_at<(p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
 AND r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
 AND r.id<>'3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
 AND r.tax_entity_id IS DISTINCT FROM '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
 UNION SELECT r.id,r.name,s.tax_entity_id FROM store_receipts s JOIN public.restaurants r ON r.id=s.store_id
 UNION SELECT r.id,r.name,s.tax_entity_id FROM store_payments s JOIN public.restaurants r ON r.id=s.store_id
 UNION SELECT r.id,r.name,r.tax_entity_id FROM store_activity a JOIN registry_sellers r ON r.id=a.store_id
 WHERE r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
 AND r.id<>'3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
 AND r.tax_entity_id IS DISTINCT FROM '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid),
 store_summaries AS(SELECT s.tax_entity_id,jsonb_agg(jsonb_build_object(
 'store_id',s.store_id,'store_name',s.store_name,'receipt_count',COALESCE(receipt.receipt_count,0),
 'gross',COALESCE(receipt.gross,0),'cash',COALESCE(payment.cash,0),'bank_transfer',COALESCE(payment.bank,0),'other_payments',COALESCE(payment.other,0),
 'supply',COALESCE(tax.supply,0),'vat',COALESCE(tax.vat,0),'missing_mapping_count',COALESCE(tax.missing_mapping_count,0),
 'closing_status',CASE WHEN dc.close_source='manual' THEN 'closed' WHEN receipt.receipt_count IS NOT NULL OR payment.store_id IS NOT NULL OR activity.store_id IS NOT NULL THEN 'pending' ELSE 'no_sales' END,
 'policy_ready',policy.id IS NOT NULL) ORDER BY s.store_name,s.store_id) stores
 FROM report_store_scope s LEFT JOIN store_activity activity ON activity.store_id=s.store_id LEFT JOIN store_receipts receipt ON receipt.store_id=s.store_id AND receipt.tax_entity_id=s.tax_entity_id
 LEFT JOIN store_payments payment ON payment.store_id=s.store_id AND payment.tax_entity_id=s.tax_entity_id
 LEFT JOIN store_tax tax ON tax.store_id=s.store_id AND tax.tax_entity_id=s.tax_entity_id
 LEFT JOIN public.daily_closings dc ON dc.restaurant_id=s.store_id AND dc.closing_date=p_business_date
 LEFT JOIN public.invoice_mapping_policies policy ON policy.store_id=s.store_id AND policy.tax_entity_id=s.tax_entity_id
 AND policy.effective_from<=statement_timestamp() AND policy.effective_to IS NULL GROUP BY s.tax_entity_id),
 bunsik_scope AS MATERIALIZED(SELECT r.id,r.name,s.tax_entity_id FROM public.restaurants r
 JOIN (SELECT store_id,tax_entity_id FROM store_receipts UNION SELECT store_id,tax_entity_id FROM store_payments
 UNION SELECT a.store_id,r.tax_entity_id FROM store_activity a JOIN registry_sellers r ON r.id=a.store_id
 WHERE r.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid) s ON s.store_id=r.id
 WHERE r.id<>'3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
 AND s.tax_entity_id IS DISTINCT FROM '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid),
$ctes$||substr(d,b);
  -- Resolve the cash's legal entity at payment time, also after a transfer.
  d:=replace(d,'FROM day_payments p JOIN bunsik_scope s ON s.id=p.restaurant_id',
   'FROM day_payments p JOIN payment_entities pe ON pe.id=p.id JOIN bunsik_scope s ON s.id=p.restaurant_id AND s.tax_entity_id=pe.tax_entity_id');
  d:=replace(d,'SELECT p.restaurant_id,sum(COALESCE(p.amount_portion,p.amount))',
   'SELECT p.restaurant_id,pe.tax_entity_id,sum(COALESCE(p.amount_portion,p.amount))');
  d:=replace(d,'GROUP BY p.restaurant_id)', 'GROUP BY p.restaurant_id,pe.tax_entity_id)');
  d:=replace(d,'all_cash.restaurant_id=s.id','all_cash.restaurant_id=s.id AND all_cash.tax_entity_id=s.tax_entity_id');
  d:=replace(d,'ON c.restaurant_id=s.id','ON c.restaurant_id=s.id AND c.tax_entity_id=s.tax_entity_id');
  d:=replace(d,'''restaurant_cash'',COALESCE(c.cash,0),',
   '''restaurant_stores'',COALESCE(store_summary.stores,''[]''::jsonb),''restaurant_cash'',COALESCE(c.cash,0),');
  d:=replace(d,'LEFT JOIN bunsik bu ON bu.tax_entity_id=e.tax_entity_id',
   'LEFT JOIN bunsik bu ON bu.tax_entity_id=e.tax_entity_id LEFT JOIN store_summaries store_summary ON store_summary.tax_entity_id=e.tax_entity_id');
  d:=replace(d,'entities AS(SELECT tax_entity_id FROM restaurant UNION',
   'entities AS(SELECT tax_entity_id FROM report_store_scope UNION SELECT tax_entity_id FROM restaurant UNION');
  EXECUTE d;
 END LOOP;
END $patch$;
DO $verify$
DECLARE signature text; d text;
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.get_pos_daily_sales_summary(date)','public.get_pos_daily_sales_summary(date,boolean)'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  IF strpos(d,'''restaurant_stores''')=0 OR strpos(d,'brand_id=''a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878''')>0
   OR has_function_privilege('anon',signature,'EXECUTE') THEN RAISE EXCEPTION 'ALL_STORE_SALES_SCOPE_DRIFT'; END IF;
 END LOOP;
END $verify$;
COMMIT;
