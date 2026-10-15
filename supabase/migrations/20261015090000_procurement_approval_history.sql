-- production-gate: self-verifying
-- 내 결재 이력은 현재 단계가 아닌 보존된 결재 이벤트로 조회한다.
BEGIN;
CREATE INDEX IF NOT EXISTS procurement_events_actor_decisions
 ON public.procurement_events(restaurant_id,(actor->>'system'),(actor->>'subject_id'),record_id)
 WHERE action IN ('store_approve','brand_approve','office_approve','senior_approve','return_request');

CREATE OR REPLACE FUNCTION public.procurement_workspace_page_core(p_store_id uuid,p_query jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
<<workspace>>
DECLARE actor jsonb;policy jsonb;prices boolean;estimates boolean;lim integer;result jsonb;requests jsonb;orders jsonb;catalog jsonb;request_counts jsonb;
 created_sort boolean:=p_query->>'request_sort'='created';
 submitted_sort boolean:=p_query->>'request_sort'='submitted';
 approval_view boolean:=COALESCE((p_query->>'approval_view')::boolean,false);
 rid uuid:=NULLIF(p_query->>'request_id','')::uuid;oid uuid:=NULLIF(p_query->>'order_id','')::uuid;
BEGIN
 actor:=public.procurement_inbox_actor(p_store_id,p_office_actor);prices:=COALESCE((actor->>'can_view_prices')::boolean,false);
 SELECT to_jsonb(p) INTO policy FROM public.procurement_store_policies p WHERE restaurant_id=p_store_id;
 estimates:=prices OR COALESCE((policy->>'two_stage_required')::boolean,false) OR COALESCE((policy->>'three_stage_required')::boolean,false);
 IF p_query->'selected_product_ids' IS NOT NULL AND (jsonb_typeof(p_query->'selected_product_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(p_query->'selected_product_ids')>200) THEN RAISE EXCEPTION 'PROCUREMENT_FILTER_INVALID'; END IF;
 IF p_query->'selected_product_ids' IS NOT NULL AND EXISTS(SELECT 1 FROM jsonb_array_elements_text(p_query->'selected_product_ids') selected LEFT JOIN public.inventory_products p ON p.id=selected::uuid AND p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable WHERE p.id IS NULL) THEN RAISE EXCEPTION 'PROCUREMENT_PRODUCT_INVALID'; END IF;
 IF NULLIF(p_query->>'purchase_category','') IS NOT NULL AND p_query->>'purchase_category' NOT IN ('raw_material','tools','stationery','beverage','other') THEN RAISE EXCEPTION 'PROCUREMENT_FILTER_INVALID'; END IF;
 IF NULLIF(p_query->>'request_scope','') IS NOT NULL AND p_query->>'request_scope' NOT IN ('mine','history','all') THEN RAISE EXCEPTION 'PROCUREMENT_FILTER_INVALID'; END IF;
 IF approval_view AND NOT COALESCE((actor->>'can_store_approve')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 IF NULLIF(p_query->>'request_group','') IS NOT NULL AND NOT(p_query->>'request_group' IN ('pending','approved','cancelled') OR approval_view AND p_query->>'request_group'='returned') THEN RAISE EXCEPTION 'PROCUREMENT_FILTER_INVALID'; END IF;
 IF NULLIF(p_query->>'created_from','') IS NOT NULL AND NULLIF(p_query->>'created_to','') IS NOT NULL AND (p_query->>'created_from')::date>(p_query->>'created_to')::date THEN RAISE EXCEPTION 'PROCUREMENT_FILTER_INVALID'; END IF;
 lim:=greatest(1,least(50,COALESCE((p_query->>'limit')::integer,20)));
 IF COALESCE((p_query->>'catalog_only')::boolean,false) THEN
 WITH products AS (SELECT p.*,it.current_stock,it.updated_at stock_updated_at FROM public.inventory_products p
   LEFT JOIN public.inventory_items it ON it.id=p.inventory_item_id AND it.restaurant_id=p_store_id
   WHERE p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable
   AND (p_query->'selected_product_ids' IS NULL OR p.id IN(SELECT value::text::uuid FROM jsonb_array_elements_text(p_query->'selected_product_ids') value))
   AND (NULLIF(p_query->>'catalog_after','') IS NULL OR p.id>(p_query->>'catalog_after')::uuid)
   AND (NULLIF(p_query->>'catalog_search','') IS NULL OR p.name ILIKE '%'||(p_query->>'catalog_search')||'%' OR p.product_code ILIKE '%'||(p_query->>'catalog_search')||'%') ORDER BY p.id LIMIT 201)
 SELECT jsonb_build_object('products',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'product_code',p.product_code,'specification',p.specification,
   'receipt_classification',p.receipt_classification,'stock_unit',p.stock_unit,'base_unit',p.base_unit,'conversion',p.base_unit_factor,'current_stock',p.current_stock,'stock_updated_at',p.stock_updated_at) ORDER BY p.id) FROM (SELECT * FROM products LIMIT 200) p),'[]'),
   'catalog_has_more',(SELECT count(*)>200 FROM products),'supplier_items',COALESCE((SELECT jsonb_agg(
     (CASE WHEN estimates THEN to_jsonb(si) ELSE to_jsonb(si)-'unit_price'-'tax_rate' END)||jsonb_build_object('supplier_name',s.supplier_name,'product_name',p.name,'payment_terms',s.payment_terms) ORDER BY si.product_id,si.id)
     FROM public.inventory_supplier_items si JOIN (SELECT * FROM products LIMIT 200) p ON p.id=si.product_id JOIN public.inventory_suppliers s ON s.id=si.supplier_id
     WHERE si.is_active AND s.status='active' AND (s.brand_id IS NULL OR s.brand_id=(SELECT brand_id FROM public.restaurants WHERE id=p_store_id))),'[]')) INTO catalog;
 RETURN catalog||jsonb_build_object('contract_version',2,'store_id',p_store_id);
 END IF;
 WITH processed AS MATERIALIZED (
   SELECT DISTINCT ev.record_id FROM public.procurement_events ev
   WHERE (approval_view OR p_query->>'request_scope'='history') AND ev.restaurant_id=p_store_id
     AND ev.actor->>'system'=workspace.actor->>'system' AND ev.actor->>'subject_id'=workspace.actor->>'subject_id'
     AND ev.action IN ('store_approve','brand_approve','office_approve','senior_approve','return_request')
 ), filtered AS MATERIALIZED (SELECT r.*,public.procurement_allowed_actions(r,actor) inbox_actions,
   CASE WHEN r.status='cancelled' THEN 'cancelled'
     WHEN r.status='returned' AND r.id IN(SELECT record_id FROM processed) THEN 'returned'
     WHEN r.status NOT IN ('draft','returned','submitted','cancelled')
       AND r.store_approved_actor->>'system'=actor->>'system' AND r.store_approved_actor->>'subject_id'=actor->>'subject_id' THEN 'approved'
     WHEN public.procurement_inbox_stage(r,actor) THEN 'pending' END manager_group
   FROM public.inventory_purchase_requests r WHERE r.restaurant_id=p_store_id
   AND(approval_view OR NULLIF(p_query->>'request_scope','') IS NULL OR p_query->>'request_scope'='all' OR p_query->>'request_scope'='mine' AND public.procurement_inbox_stage(r,actor)
     OR p_query->>'request_scope'='history' AND r.id IN (SELECT record_id FROM processed))
   AND(NULLIF(p_query->>'purchase_category','') IS NULL OR r.purchase_category=p_query->>'purchase_category'
     OR p_query->>'purchase_category'='tools' AND r.purchase_category='stationery')
   AND(NULLIF(p_query->>'search','') IS NULL OR r.request_no ILIKE '%'||(p_query->>'search')||'%' OR r.reason ILIKE '%'||(p_query->>'search')||'%')
   AND(NULLIF(p_query->>'created_from','') IS NULL OR r.created_at >= ((p_query->>'created_from')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'))
   AND(NULLIF(p_query->>'created_to','') IS NULL OR r.created_at < (((p_query->>'created_to')::date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'))
 ), page AS (SELECT r.* FROM filtered r
   WHERE(NULLIF(p_query->>'request_status','') IS NULL OR r.status=p_query->>'request_status')
   AND(approval_view AND r.manager_group=COALESCE(NULLIF(p_query->>'request_group',''),'pending')
     OR NOT approval_view AND (NULLIF(p_query->>'request_group','') IS NULL
     OR p_query->>'request_group'='pending' AND r.status IN ('draft','returned','submitted','brand_review','office_review','senior_review')
     OR p_query->>'request_group'='approved' AND r.status IN ('approved','allocated')
     OR p_query->>'request_group'='cancelled' AND r.status='cancelled'))
   AND (NULLIF(p_query->>'request_before','') IS NULL
     OR submitted_sort AND (COALESCE(r.submitted_at,r.created_at),r.id)>((p_query->>'request_before')::timestamptz,(p_query->>'request_before_id')::uuid)
     OR NOT submitted_sort AND (CASE WHEN created_sort THEN r.created_at ELSE r.updated_at END,r.id)<((p_query->>'request_before')::timestamptz,(p_query->>'request_before_id')::uuid))
   ORDER BY CASE WHEN submitted_sort THEN COALESCE(r.submitted_at,r.created_at) END ASC,
     CASE WHEN NOT submitted_sort THEN CASE WHEN created_sort THEN r.created_at ELSE r.updated_at END END DESC,
     CASE WHEN submitted_sort THEN r.id END ASC,CASE WHEN NOT submitted_sort THEN r.id END DESC LIMIT lim+1), counts AS (
   SELECT l.request_id,count(*) line_count,sum(l.quantity_base) quantity_base FROM public.inventory_purchase_request_lines l JOIN page p ON p.id=l.request_id WHERE l.active GROUP BY l.request_id)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',p.id,'request_no',p.request_no,'status',p.status,'row_version',p.row_version,'reason',p.reason,
   'created_at',p.created_at,'updated_at',p.updated_at,'submitted_at',p.submitted_at,'requested_delivery_date',p.requested_delivery_date,
   'purchase_category',p.purchase_category,'purchase_channel',p.purchase_channel,'approval_policy_version',p.approval_policy_version,
   'requester_name',p.created_actor->>'display_name','requester_role',p.created_actor->>'role','approval_group',p.manager_group,
   'line_count',COALESCE(c.line_count,0),'allowed_actions',CASE WHEN COALESCE((policy->>'enabled')::boolean,false) THEN p.inbox_actions ELSE '[]' END,
   'lines','[]'::jsonb,'quotes','[]'::jsonb) ORDER BY CASE WHEN submitted_sort THEN COALESCE(p.submitted_at,p.created_at) END ASC,CASE WHEN NOT submitted_sort THEN CASE WHEN created_sort THEN p.created_at ELSE p.updated_at END END DESC,CASE WHEN submitted_sort THEN p.id END ASC,CASE WHEN NOT submitted_sort THEN p.id END DESC),'[]'),
   (SELECT CASE WHEN approval_view THEN jsonb_build_object(
      'pending',count(*) FILTER(WHERE manager_group='pending'),'approved',count(*) FILTER(WHERE manager_group='approved'),
      'returned',count(*) FILTER(WHERE manager_group='returned'),'cancelled',count(*) FILTER(WHERE manager_group='cancelled'))
    ELSE jsonb_build_object('pending',count(*) FILTER(WHERE status IN ('draft','returned','submitted','brand_review','office_review','senior_review')),
    'approved',count(*) FILTER(WHERE status IN ('approved','allocated')),'cancelled',count(*) FILTER(WHERE status='cancelled')) END FROM filtered)
 INTO requests,request_counts FROM page p LEFT JOIN counts c ON c.request_id=p.id;
 WITH page AS (SELECT po.* FROM public.inventory_purchase_orders po WHERE po.restaurant_id=p_store_id AND po.workflow_version=2
   AND(NOT COALESCE((p_query->>'request_view')::boolean,false) OR rid IS NOT NULL)
   AND(rid IS NULL OR po.commercial_terms->>'request_id'=rid::text)
   AND(NULLIF(p_query->>'search','') IS NULL OR po.purchase_order_no ILIKE '%'||(p_query->>'search')||'%' OR po.commercial_terms->>'pr_no' ILIKE '%'||(p_query->>'search')||'%')
   AND (NULLIF(p_query->>'order_before','') IS NULL OR (po.created_at,po.id)<((p_query->>'order_before')::timestamptz,(p_query->>'order_before_id')::uuid))
   ORDER BY po.created_at DESC,po.id DESC LIMIT lim+1)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',p.id,'purchase_order_no',p.purchase_order_no,'status',p.status,'procurement_status',p.procurement_status,
   'row_version',p.row_version,'created_at',p.created_at,'requested_delivery_date',p.requested_delivery_date,'commercial_revision',p.commercial_revision,
   'receiving_outcome',p.commercial_terms->>'receiving_outcome','supplier_name',s.supplier_name,'pr_no',p.commercial_terms->'pr_no','pr_created_at',p.commercial_terms->'pr_created_at','pr_submitted_at',p.commercial_terms->'pr_submitted_at',
   'issued_at',p.commercial_terms->'issued_at','accounting_status',to_jsonb(a)||jsonb_build_object('stale',a.observed_at<now()-interval '10 minutes' OR a.source_order_version<>p.row_version),'allowed_actions',CASE WHEN COALESCE((policy->>'enabled')::boolean,false) AND COALESCE((actor->>'can_office_approve')::boolean,false)
     THEN CASE p.procurement_status WHEN 'issued' THEN '["send_po"]'::jsonb WHEN 'sent' THEN '["confirm_po"]'::jsonb ELSE '[]'::jsonb END ELSE '[]'::jsonb END) ORDER BY p.created_at DESC,p.id DESC),'[]')
 INTO orders FROM page p LEFT JOIN public.inventory_suppliers s ON s.id=p.supplier_id LEFT JOIN public.procurement_accounting_status a ON a.purchase_order_id=p.id;
 IF NOT COALESCE((p_query->>'request_summary_only')::boolean,false) THEN
 WITH products AS (SELECT p.*,it.current_stock,it.updated_at stock_updated_at FROM public.inventory_products p
   LEFT JOIN public.inventory_items it ON it.id=p.inventory_item_id AND it.restaurant_id=p_store_id
   WHERE p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable
   AND (p_query->'selected_product_ids' IS NULL OR p.id IN(SELECT value::text::uuid FROM jsonb_array_elements_text(p_query->'selected_product_ids') value))
   AND (NULLIF(p_query->>'catalog_after','') IS NULL OR p.id>(p_query->>'catalog_after')::uuid)
   AND (NULLIF(p_query->>'catalog_search','') IS NULL OR p.name ILIKE '%'||(p_query->>'catalog_search')||'%' OR p.product_code ILIKE '%'||(p_query->>'catalog_search')||'%') ORDER BY p.id LIMIT 201)
 SELECT jsonb_build_object('products',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'product_code',p.product_code,'specification',p.specification,
   'receipt_classification',p.receipt_classification,'stock_unit',p.stock_unit,'base_unit',p.base_unit,'conversion',p.base_unit_factor,'current_stock',p.current_stock,'stock_updated_at',p.stock_updated_at) ORDER BY p.id) FROM (SELECT * FROM products LIMIT 200) p),'[]'),
   'catalog_has_more',(SELECT count(*)>200 FROM products),'supplier_items',COALESCE((SELECT jsonb_agg(
     (CASE WHEN estimates THEN to_jsonb(si) ELSE to_jsonb(si)-'unit_price'-'tax_rate' END)||jsonb_build_object('supplier_name',s.supplier_name,'product_name',p.name,'payment_terms',s.payment_terms) ORDER BY si.product_id,si.id)
     FROM public.inventory_supplier_items si JOIN (SELECT * FROM products LIMIT 200) p ON p.id=si.product_id JOIN public.inventory_suppliers s ON s.id=si.supplier_id
     WHERE si.is_active AND s.status='active' AND (s.brand_id IS NULL OR s.brand_id=(SELECT brand_id FROM public.restaurants WHERE id=p_store_id))),'[]')) INTO catalog;
 ELSE catalog:='{"products":[],"supplier_items":[],"catalog_has_more":false}'::jsonb; END IF;
 result:=jsonb_build_object('contract_version',2,'read_contract','paged','store_id',p_store_id,'enabled',COALESCE((policy->>'enabled')::boolean,false),
   'actor',actor-'identity_people','policy',policy,'requests',COALESCE((SELECT jsonb_agg(x) FROM jsonb_array_elements(requests) WITH ORDINALITY a(x,n) WHERE n<=lim),'[]'),
   'orders',COALESCE((SELECT jsonb_agg(x) FROM jsonb_array_elements(orders) WITH ORDINALITY a(x,n) WHERE n<=lim),'[]'),
   'request_counts',request_counts,'request_sort',CASE WHEN submitted_sort THEN 'submitted' WHEN created_sort THEN 'created' ELSE 'updated' END,
   'request_has_more',jsonb_array_length(requests)>lim,'order_has_more',jsonb_array_length(orders)>lim,'events','[]'::jsonb,
   'receipts','[]'::jsonb,'issues','[]'::jsonb,'returns','[]'::jsonb)||catalog;
 IF rid IS NOT NULL THEN
   IF NOT EXISTS(SELECT 1 FROM public.inventory_purchase_requests WHERE id=rid AND restaurant_id=p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
   WITH quote_page AS MATERIALIZED(SELECT * FROM public.procurement_quotes WHERE request_id=rid AND NOT archived
     AND(NULLIF(p_query->>'quote_before','') IS NULL OR(created_at,id)<((p_query->>'quote_before')::timestamptz,(p_query->>'quote_before_id')::uuid)) ORDER BY created_at DESC,id DESC LIMIT 21), qlines AS (SELECT l.quote_id,jsonb_agg(to_jsonb(l) ORDER BY l.id) lines FROM public.procurement_quote_lines l JOIN (SELECT * FROM quote_page ORDER BY created_at DESC,id DESC LIMIT 20) q ON q.id=l.quote_id GROUP BY l.quote_id),
   quotes AS (SELECT jsonb_agg(to_jsonb(q)||jsonb_build_object('supplier_name',s.supplier_name,'lines',l.lines) ORDER BY q.created_at DESC,q.id DESC) rows
     FROM (SELECT * FROM quote_page ORDER BY created_at DESC,id DESC LIMIT 20) q JOIN public.inventory_suppliers s ON s.id=q.supplier_id LEFT JOIN qlines l ON l.quote_id=q.id WHERE q.request_id=rid AND NOT q.archived),
   lines AS (SELECT jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',COALESCE(l.product_name_snapshot,p.name),'product_code',COALESCE(l.product_code_snapshot,p.product_code)) ORDER BY l.line_position,l.id) rows FROM public.inventory_purchase_request_lines l JOIN public.inventory_products p ON p.id=l.product_id WHERE l.request_id=rid AND l.active)
   SELECT result||jsonb_build_object('quote_has_more',prices AND (SELECT count(*)>20 FROM quote_page),'request_detail',(CASE WHEN prices THEN to_jsonb(r) ELSE to_jsonb(r)-'approved_amount' END)||jsonb_build_object('lines',COALESCE(l.rows,'[]'),'quotes',CASE WHEN prices THEN COALESCE(q.rows,'[]') ELSE '[]' END,
     'allowed_actions',CASE WHEN COALESCE((policy->>'enabled')::boolean,false) THEN public.procurement_allowed_actions(r,actor) ELSE '[]' END)) INTO result FROM public.inventory_purchase_requests r CROSS JOIN quotes q CROSS JOIN lines l WHERE r.id=rid;
 END IF;
 IF oid IS NOT NULL THEN
   IF NOT EXISTS(SELECT 1 FROM public.inventory_purchase_orders WHERE id=oid AND restaurant_id=p_store_id AND workflow_version=2) THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
   SELECT result||jsonb_build_object('order_detail',(CASE WHEN prices THEN to_jsonb(po) ELSE to_jsonb(po)-'total_amount'-'total_supply_amount'-'tax_amount'-'approval_snapshot' END)||jsonb_build_object('supplier_name',s.supplier_name,'accounting_status',to_jsonb(a)||jsonb_build_object('stale',a.observed_at<now()-interval '10 minutes' OR a.source_order_version<>po.row_version),
     'allowed_actions',CASE WHEN COALESCE((policy->>'enabled')::boolean,false) AND COALESCE((actor->>'can_office_approve')::boolean,false) THEN CASE po.procurement_status WHEN 'issued' THEN '["send_po"]'::jsonb WHEN 'sent' THEN '["confirm_po"]'::jsonb ELSE '[]'::jsonb END ELSE '[]'::jsonb END))
   INTO result FROM public.inventory_purchase_orders po LEFT JOIN public.inventory_suppliers s ON s.id=po.supplier_id LEFT JOIN public.procurement_accounting_status a ON a.purchase_order_id=po.id WHERE po.id=oid;
   WITH receipt_page AS (SELECT * FROM public.inventory_receipts WHERE purchase_order_id=oid AND(NULLIF(p_query->>'receipt_before','') IS NULL OR(received_at,id)<((p_query->>'receipt_before')::timestamptz,(p_query->>'receipt_before_id')::uuid)) ORDER BY received_at DESC,id DESC LIMIT 21),
   lines AS (SELECT l.receipt_id,jsonb_agg((CASE WHEN prices THEN to_jsonb(l) ELSE to_jsonb(l)-'actual_unit_price'-'final_supply_amount'-'final_tax_amount' END)||jsonb_build_object('product_name',p.name) ORDER BY l.id) rows
     FROM public.inventory_receipt_lines l JOIN receipt_page r ON r.id=l.receipt_id JOIN public.inventory_products p ON p.id=l.product_id GROUP BY l.receipt_id)
   SELECT result||jsonb_build_object('receipt_has_more',(SELECT count(*)>20 FROM receipt_page),'receipts',COALESCE(jsonb_agg((CASE WHEN prices THEN to_jsonb(r) ELSE to_jsonb(r)-'total_amount'-'total_supply_amount'-'tax_amount' END)||jsonb_build_object('lines',COALESCE(l.rows,'[]')) ORDER BY r.received_at DESC,r.id DESC),'[]')) INTO result FROM (SELECT * FROM receipt_page ORDER BY received_at DESC,id DESC LIMIT 20) r LEFT JOIN lines l ON l.receipt_id=r.id;
   WITH page AS(SELECT * FROM public.inventory_receipt_issues WHERE purchase_order_id=oid AND(NULLIF(p_query->>'issue_before','') IS NULL OR(created_at,id)<((p_query->>'issue_before')::timestamptz,(p_query->>'issue_before_id')::uuid)) ORDER BY created_at DESC,id DESC LIMIT 51)
   SELECT result||jsonb_build_object('issue_has_more',(SELECT count(*)>50 FROM page),'issues',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC) FROM(SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT 50) x),'[]')) INTO result;
   WITH page AS(SELECT * FROM public.inventory_supplier_returns WHERE purchase_order_id=oid AND(NULLIF(p_query->>'return_before','') IS NULL OR(created_at,id)<((p_query->>'return_before')::timestamptz,(p_query->>'return_before_id')::uuid)) ORDER BY created_at DESC,id DESC LIMIT 51)
   SELECT result||jsonb_build_object('return_has_more',(SELECT count(*)>50 FROM page),'returns',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC) FROM(SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT 50) x),'[]')) INTO result;

 END IF;
 IF rid IS NOT NULL OR oid IS NOT NULL THEN
   WITH page AS(SELECT ev.id,ev.record_id,ev.action,ev.actor,ev.reason,ev.created_at FROM public.procurement_events ev
     WHERE ev.restaurant_id=p_store_id AND ev.record_id IN(rid,oid) AND(NULLIF(p_query->>'event_before','') IS NULL OR(ev.created_at,ev.id)<((p_query->>'event_before')::timestamptz,(p_query->>'event_before_id')::uuid)) ORDER BY ev.created_at DESC,ev.id DESC LIMIT 101)
   SELECT result||jsonb_build_object('event_has_more',(SELECT count(*)>100 FROM page),'events',COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.created_at DESC,e.id DESC) FROM(SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT 100) e),'[]')) INTO result;

 END IF;
 IF NULLIF(p_query->>'issue_followup_id','') IS NOT NULL THEN
   IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_OFFICE_FORBIDDEN'; END IF;
   WITH issue AS(SELECT i.*,l.product_id,r.created_at received_at,po.supplier_id FROM public.inventory_receipt_issues i JOIN public.inventory_receipt_lines l ON l.id=i.receipt_line_id JOIN public.inventory_receipts r ON r.id=l.receipt_id JOIN public.inventory_purchase_orders po ON po.id=i.purchase_order_id
     WHERE i.id=(p_query->>'issue_followup_id')::uuid AND i.restaurant_id=p_store_id),
   candidates AS MATERIALIZED(SELECT l.id,l.accepted_quantity_base,r.created_at,r.received_at,r.statement_number,po.purchase_order_no,p.name product_name
     FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id JOIN public.inventory_purchase_orders po ON po.id=r.purchase_order_id JOIN public.inventory_products p ON p.id=l.product_id JOIN issue i ON i.product_id=l.product_id AND i.supplier_id=po.supplier_id
     WHERE r.restaurant_id=p_store_id AND r.status='confirmed' AND l.id<>i.receipt_line_id AND r.created_at>=i.received_at AND l.accepted_quantity_base>0
       AND(NULLIF(p_query->>'followup_search','') IS NULL OR po.purchase_order_no ILIKE '%'||(p_query->>'followup_search')||'%' OR r.statement_number ILIKE '%'||(p_query->>'followup_search')||'%')
       AND(NULLIF(p_query->>'followup_before','') IS NULL OR(r.created_at,l.id)<((p_query->>'followup_before')::timestamptz,(p_query->>'followup_before_id')::uuid)) ORDER BY r.created_at DESC,l.id DESC LIMIT 21),
   returned AS(SELECT t.receipt_line_id,sum(t.quantity_base) quantity FROM public.inventory_supplier_returns t JOIN candidates c ON c.id=t.receipt_line_id GROUP BY t.receipt_line_id)
   SELECT result||jsonb_build_object('followup_has_more',(SELECT count(*)>20 FROM candidates),'followup_receipt_lines',COALESCE(jsonb_agg(to_jsonb(c)||jsonb_build_object('net_accepted_quantity',c.accepted_quantity_base-COALESCE(t.quantity,0)) ORDER BY c.created_at DESC,c.id DESC),'[]')) INTO result
   FROM(SELECT * FROM candidates ORDER BY created_at DESC,id DESC LIMIT 20)c LEFT JOIN returned t ON t.receipt_line_id=c.id;
 END IF;
 IF prices AND COALESCE((p_query->>'include_legacy')::boolean,false) THEN
   WITH page AS MATERIALIZED(SELECT po.* FROM public.inventory_purchase_orders po WHERE po.restaurant_id=p_store_id AND po.workflow_version=1
     AND po.status IN ('ordered','partially_received','office_approved') AND EXISTS(SELECT 1 FROM public.inventory_purchase_order_lines l WHERE l.purchase_order_id=po.id AND (l.order_unit_quantity_base_snapshot IS NULL OR l.tax_rate_snapshot IS NULL))
     AND(NULLIF(p_query->>'legacy_before','') IS NULL OR(po.created_at,po.id)<((p_query->>'legacy_before')::timestamptz,(p_query->>'legacy_before_id')::uuid)) ORDER BY po.created_at DESC,po.id DESC LIMIT 21),
   lines AS(SELECT l.purchase_order_id,jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',p.name,'current_base_unit',p.base_unit) ORDER BY l.id) rows
     FROM public.inventory_purchase_order_lines l JOIN(SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT 20) po ON po.id=l.purchase_order_id JOIN public.inventory_products p ON p.id=l.product_id GROUP BY l.purchase_order_id)
   SELECT result||jsonb_build_object('legacy_has_more',(SELECT count(*)>20 FROM page),'legacy_terms_review',COALESCE(jsonb_agg(to_jsonb(po)||jsonb_build_object('lines',COALESCE(l.rows,'[]')) ORDER BY po.created_at DESC,po.id DESC),'[]')) INTO result
     FROM(SELECT * FROM page ORDER BY created_at DESC,id DESC LIMIT 20) po LEFT JOIN lines l ON l.purchase_order_id=po.id;
 END IF;
 IF COALESCE((p_query->>'include_evidence')::boolean,false) THEN result:=result||public.procurement_supplier_evidence(p_store_id,p_office_actor)||jsonb_build_object('demand',public.procurement_demand_evidence(p_store_id,p_office_actor)); END IF;
 WITH pending AS MATERIALIZED (SELECT r.*,CASE WHEN COALESCE((policy->>'enabled')::boolean,false) THEN public.procurement_allowed_actions(r,actor) ELSE '[]'::jsonb END actions FROM public.inventory_purchase_requests r
   WHERE r.restaurant_id=p_store_id AND r.status IN ('submitted','brand_review','office_review','senior_review'))
 SELECT result||jsonb_build_object('approval_counts',jsonb_build_object('pending',count(*),
  'actionable',count(*) FILTER(WHERE actions ?| ARRAY['store_approve','brand_approve','office_approve','senior_approve']),
  'blocked',count(*) FILTER(WHERE public.procurement_inbox_stage(jsonb_populate_record(NULL::public.inventory_purchase_requests,to_jsonb(r)),actor) AND NOT(actions ?| ARRAY['store_approve','brand_approve','office_approve','senior_approve']))))
 INTO result FROM pending r;
 RETURN result;
END $$;

DO $$ BEGIN
 IF position('processed AS MATERIALIZED' IN pg_get_functiondef('public.procurement_workspace_page_core(uuid,jsonb,jsonb)'::regprocedure))=0
 OR position('manager_group' IN pg_get_functiondef('public.procurement_workspace_page_core(uuid,jsonb,jsonb)'::regprocedure))=0
 OR position('request_summary_only' IN pg_get_functiondef('public.procurement_workspace_page_core(uuid,jsonb,jsonb)'::regprocedure))=0
 OR to_regclass('public.procurement_events_actor_decisions') IS NULL
 OR has_function_privilege('anon','public.procurement_workspace_page(uuid,jsonb,jsonb)','EXECUTE')
 THEN RAISE EXCEPTION 'PROCUREMENT_HISTORY_CONTRACT_INVALID'; END IF;
END $$;
COMMIT;
