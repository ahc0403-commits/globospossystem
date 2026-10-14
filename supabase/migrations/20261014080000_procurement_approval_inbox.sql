-- PR inbox and payload-free invalidations. Historical approval transitions stay in their original command.
-- production-gate: self-verifying
BEGIN;
CREATE INDEX IF NOT EXISTS procurement_requests_store_submitted
 ON public.inventory_purchase_requests(restaurant_id,COALESCE(submitted_at,created_at),id)
 WHERE status IN ('submitted','brand_review','office_review','senior_review');


ALTER FUNCTION public.can_create_inventory_purchase_order(uuid) RENAME TO procurement_pre_inbox_can_create_order;
REVOKE ALL ON FUNCTION public.procurement_pre_inbox_can_create_order(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.can_create_inventory_purchase_order(p_store_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
 SELECT public.procurement_pre_inbox_can_create_order(p_store_id) AND NOT EXISTS(
  SELECT 1 FROM public.users u JOIN public.store_fixed_account_requirements q ON q.provisioned_user_id=u.id AND q.store_id=p_store_id AND q.is_active AND q.scope='store'
  WHERE u.auth_id=auth.uid() AND u.is_active AND u.role='inventory_orderer'
  AND NOT EXISTS(SELECT 1 FROM public.procurement_role_roster rr WHERE rr.restaurant_id=p_store_id AND rr.system='pos'
    AND rr.subject_id=u.auth_id AND rr.stage='receiver' AND rr.valid_from<=now() AND rr.valid_until>now()))
$$;
REVOKE ALL ON FUNCTION public.can_create_inventory_purchase_order(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.can_create_inventory_purchase_order(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.procurement_actor(p_store_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;people jsonb;
BEGIN
 actor:=public.procurement_actor_base(p_store_id,p_office_actor)-'person_id';
 SELECT to_jsonb(person_id) INTO people FROM public.procurement_role_roster
 WHERE restaurant_id=p_store_id AND system=actor->>'system' AND subject_id::text=actor->>'subject_id'
 AND valid_from<=now() AND valid_until>now() ORDER BY updated_at DESC LIMIT 1;
 RETURN actor||jsonb_build_object('person_id',people,'can_office_approve',CASE WHEN actor->>'role' IN ('brand_admin','brand_manager') THEN false ELSE COALESCE((actor->>'can_office_approve')::boolean,false) END,'can_receive',CASE WHEN actor->>'system'='pos' THEN public.can_create_inventory_purchase_order(p_store_id) OR public.can_verify_inventory_receipt(p_store_id) ELSE false END);
END $$;

CREATE FUNCTION public.procurement_inbox_actor(p_store_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE actor jsonb;people jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 SELECT COALESCE(jsonb_object_agg(system||':'||subject_id,person_id),'{}') INTO people FROM(
 SELECT DISTINCT ON(system,subject_id) system,subject_id,person_id FROM public.procurement_role_roster
 WHERE restaurant_id=p_store_id AND valid_from<=now() AND valid_until>now() ORDER BY system,subject_id,updated_at DESC) p;
 RETURN actor||jsonb_build_object('identity_people',people);
END $$;
REVOKE ALL ON FUNCTION public.procurement_inbox_actor(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.procurement_inbox_stage(p_request public.inventory_purchase_requests,p_actor jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT COALESCE(CASE WHEN p_request.approval_policy_version=3 AND p_actor->>'role' IN ('brand_admin','brand_manager') THEN false ELSE CASE p_request.status
 WHEN 'submitted' THEN (p_actor->>'can_store_approve')::boolean
 WHEN 'brand_review' THEN p_request.approval_policy_version<>3 AND (p_actor->>'can_brand_approve')::boolean
 WHEN 'office_review' THEN (p_actor->>'can_office_approve')::boolean
 WHEN 'senior_review' THEN p_request.approval_policy_version<>3 AND (p_actor->>'can_senior_approve')::boolean
 ELSE false END END,false)
$$;
CREATE FUNCTION public.procurement_inbox_same_identity(p_left jsonb,p_actor jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT COALESCE(p_left->>'system'=p_actor->>'system' AND p_left->>'subject_id'=p_actor->>'subject_id',false)
 OR COALESCE(NULLIF(p_left->>'person_id','')=NULLIF(p_actor->>'person_id',''),false)
 OR COALESCE(NULLIF(p_actor->'identity_people'->>((p_left->>'system')||':'||(p_left->>'subject_id')),'')=NULLIF(p_actor->>'person_id',''),false)
$$;
ALTER FUNCTION public.procurement_allowed_actions(public.inventory_purchase_requests,jsonb) RENAME TO procurement_pre_inbox_actions;
REVOKE ALL ON FUNCTION public.procurement_pre_inbox_actions(public.inventory_purchase_requests,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.procurement_allowed_actions(p_request public.inventory_purchase_requests,p_actor jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actions jsonb:=public.procurement_pre_inbox_actions(p_request,p_actor);
BEGIN
 IF p_request.approval_policy_version IN (2,3) THEN
  IF public.procurement_inbox_same_identity(p_request.created_actor,p_actor) THEN
   actions:=actions-ARRAY['adjust_request','store_approve','brand_approve','office_approve','senior_approve'];
  END IF;
  IF public.procurement_inbox_same_identity(p_request.store_approved_actor,p_actor) THEN
   actions:=actions-ARRAY['brand_approve','office_approve','senior_approve'];
  END IF;
  IF p_request.approval_policy_version=2 AND public.procurement_inbox_same_identity(p_request.brand_approved_actor,p_actor) THEN
   actions:=actions-ARRAY['office_approve','senior_approve'];
  END IF;
  IF public.procurement_inbox_same_identity(p_request.office_approved_actor,p_actor) THEN
   actions:=actions-'senior_approve';
  END IF;
 END IF;
 IF p_request.approval_policy_version=3 THEN
  actions:=actions-ARRAY['brand_approve','senior_approve'];
  IF p_actor->>'role' IN ('brand_admin','brand_manager') THEN
   actions:=actions-ARRAY['adjust_request','store_approve','office_approve','return_request'];
  END IF;
 END IF;
 RETURN COALESCE(actions,'[]');
END $$;
REVOKE ALL ON FUNCTION public.procurement_inbox_stage(public.inventory_purchase_requests,jsonb),public.procurement_inbox_same_identity(jsonb,jsonb),public.procurement_allowed_actions(public.inventory_purchase_requests,jsonb) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.procurement_workspace_page_core(p_store_id uuid,p_query jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;policy jsonb;prices boolean;estimates boolean;lim integer;result jsonb;requests jsonb;orders jsonb;catalog jsonb;request_counts jsonb;
 created_sort boolean:=p_query->>'request_sort'='created';
 submitted_sort boolean:=p_query->>'request_sort'='submitted';
 rid uuid:=NULLIF(p_query->>'request_id','')::uuid;oid uuid:=NULLIF(p_query->>'order_id','')::uuid;
BEGIN
 actor:=public.procurement_inbox_actor(p_store_id,p_office_actor);prices:=COALESCE((actor->>'can_view_prices')::boolean,false);
 SELECT to_jsonb(p) INTO policy FROM public.procurement_store_policies p WHERE restaurant_id=p_store_id;
 estimates:=prices OR COALESCE((policy->>'two_stage_required')::boolean,false) OR COALESCE((policy->>'three_stage_required')::boolean,false);
 IF p_query->'selected_product_ids' IS NOT NULL AND (jsonb_typeof(p_query->'selected_product_ids') IS DISTINCT FROM 'array' OR jsonb_array_length(p_query->'selected_product_ids')>200) THEN RAISE EXCEPTION 'PROCUREMENT_FILTER_INVALID'; END IF;
 IF p_query->'selected_product_ids' IS NOT NULL AND EXISTS(SELECT 1 FROM jsonb_array_elements_text(p_query->'selected_product_ids') selected LEFT JOIN public.inventory_products p ON p.id=selected::uuid AND p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable WHERE p.id IS NULL) THEN RAISE EXCEPTION 'PROCUREMENT_PRODUCT_INVALID'; END IF;
 IF NULLIF(p_query->>'purchase_category','') IS NOT NULL AND p_query->>'purchase_category' NOT IN ('raw_material','tools','stationery','beverage','other') THEN RAISE EXCEPTION 'PROCUREMENT_FILTER_INVALID'; END IF;
 IF NULLIF(p_query->>'request_group','') IS NOT NULL AND p_query->>'request_group' NOT IN ('pending','approved','cancelled') THEN RAISE EXCEPTION 'PROCUREMENT_FILTER_INVALID'; END IF;
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
 WITH filtered AS MATERIALIZED (SELECT r.*,public.procurement_allowed_actions(r,actor) inbox_actions FROM public.inventory_purchase_requests r WHERE r.restaurant_id=p_store_id
   AND(NULLIF(p_query->>'request_scope','') IS NULL OR p_query->>'request_scope'='all' OR public.procurement_inbox_stage(r,actor))
   AND(NULLIF(p_query->>'purchase_category','') IS NULL OR r.purchase_category=p_query->>'purchase_category'
     OR p_query->>'purchase_category'='tools' AND r.purchase_category='stationery')
   AND(NULLIF(p_query->>'search','') IS NULL OR r.request_no ILIKE '%'||(p_query->>'search')||'%' OR r.reason ILIKE '%'||(p_query->>'search')||'%')
   AND(NULLIF(p_query->>'created_from','') IS NULL OR r.created_at >= ((p_query->>'created_from')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'))
   AND(NULLIF(p_query->>'created_to','') IS NULL OR r.created_at < (((p_query->>'created_to')::date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'))
 ), page AS (SELECT r.* FROM filtered r
   WHERE(NULLIF(p_query->>'request_status','') IS NULL OR r.status=p_query->>'request_status')
   AND(NULLIF(p_query->>'request_group','') IS NULL
     OR p_query->>'request_group'='pending' AND r.status IN ('draft','returned','submitted','brand_review','office_review','senior_review')
     OR p_query->>'request_group'='approved' AND r.status IN ('approved','allocated')
     OR p_query->>'request_group'='cancelled' AND r.status='cancelled')
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
   'line_count',COALESCE(c.line_count,0),'allowed_actions',CASE WHEN COALESCE((policy->>'enabled')::boolean,false) THEN p.inbox_actions ELSE '[]' END,
   'lines','[]'::jsonb,'quotes','[]'::jsonb) ORDER BY CASE WHEN submitted_sort THEN COALESCE(p.submitted_at,p.created_at) END ASC,CASE WHEN NOT submitted_sort THEN CASE WHEN created_sort THEN p.created_at ELSE p.updated_at END END DESC,CASE WHEN submitted_sort THEN p.id END ASC,CASE WHEN NOT submitted_sort THEN p.id END DESC),'[]'),
   (SELECT jsonb_build_object('pending',count(*) FILTER(WHERE status IN ('draft','returned','submitted','brand_review','office_review','senior_review')),
    'approved',count(*) FILTER(WHERE status IN ('approved','allocated')),'cancelled',count(*) FILTER(WHERE status='cancelled')) FROM filtered)
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

CREATE FUNCTION public.emit_procurement_live_statement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF TG_TABLE_NAME='inventory_purchase_request_lines' THEN
  INSERT INTO public.pos_live_events(restaurant_id,domain,source_table,event_type)
  SELECT DISTINCT r.restaurant_id,'inventory',TG_TABLE_NAME,TG_OP FROM changed_rows c JOIN public.inventory_purchase_requests r ON r.id=c.request_id;
 ELSE
  INSERT INTO public.pos_live_events(restaurant_id,domain,source_table,event_type)
  SELECT DISTINCT restaurant_id,'inventory',TG_TABLE_NAME,TG_OP FROM changed_rows;
 END IF;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.emit_procurement_live_statement() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER inventory_purchase_requests_live_insert AFTER INSERT ON public.inventory_purchase_requests REFERENCING NEW TABLE AS changed_rows FOR EACH STATEMENT EXECUTE FUNCTION public.emit_procurement_live_statement();
CREATE TRIGGER inventory_purchase_requests_live_update AFTER UPDATE ON public.inventory_purchase_requests REFERENCING NEW TABLE AS changed_rows FOR EACH STATEMENT EXECUTE FUNCTION public.emit_procurement_live_statement();
CREATE TRIGGER inventory_purchase_requests_live_delete AFTER DELETE ON public.inventory_purchase_requests REFERENCING OLD TABLE AS changed_rows FOR EACH STATEMENT EXECUTE FUNCTION public.emit_procurement_live_statement();
CREATE TRIGGER inventory_purchase_request_lines_live_insert AFTER INSERT ON public.inventory_purchase_request_lines REFERENCING NEW TABLE AS changed_rows FOR EACH STATEMENT EXECUTE FUNCTION public.emit_procurement_live_statement();
CREATE TRIGGER inventory_purchase_request_lines_live_update AFTER UPDATE ON public.inventory_purchase_request_lines REFERENCING NEW TABLE AS changed_rows FOR EACH STATEMENT EXECUTE FUNCTION public.emit_procurement_live_statement();
CREATE TRIGGER inventory_purchase_request_lines_live_delete AFTER DELETE ON public.inventory_purchase_request_lines REFERENCING OLD TABLE AS changed_rows FOR EACH STATEMENT EXECUTE FUNCTION public.emit_procurement_live_statement();
CREATE TRIGGER procurement_events_live_insert AFTER INSERT ON public.procurement_events REFERENCING NEW TABLE AS changed_rows FOR EACH STATEMENT EXECUTE FUNCTION public.emit_procurement_live_statement();
CREATE TRIGGER procurement_events_live_update AFTER UPDATE ON public.procurement_events REFERENCING NEW TABLE AS changed_rows FOR EACH STATEMENT EXECUTE FUNCTION public.emit_procurement_live_statement();
CREATE TRIGGER procurement_events_live_delete AFTER DELETE ON public.procurement_events REFERENCING OLD TABLE AS changed_rows FOR EACH STATEMENT EXECUTE FUNCTION public.emit_procurement_live_statement();

CREATE OR REPLACE FUNCTION public.get_inventory_workflow_detail(p_purchase_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE po public.inventory_purchase_orders%rowtype;result jsonb;
BEGIN
 SELECT * INTO po FROM public.inventory_purchase_orders WHERE id=p_purchase_order_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND'; END IF;
 IF NOT public.can_access_inventory_workflow(po.restaurant_id) THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN'; END IF;
 WITH accepted AS(SELECT rl.purchase_order_line_id,sum(rl.accepted_quantity_base) qty FROM public.inventory_receipt_lines rl JOIN public.inventory_receipts r ON r.id=rl.receipt_id WHERE r.purchase_order_id=po.id AND r.status='confirmed' GROUP BY rl.purchase_order_line_id),
 receipt_page AS MATERIALIZED(SELECT * FROM public.inventory_receipts WHERE purchase_order_id=po.id ORDER BY created_at DESC,id DESC LIMIT 21),
 receipt_lines AS(SELECT rl.receipt_id,jsonb_agg(to_jsonb(rl) ORDER BY rl.id) rows FROM public.inventory_receipt_lines rl JOIN (SELECT * FROM receipt_page ORDER BY created_at DESC,id DESC LIMIT 20) r ON r.id=rl.receipt_id GROUP BY rl.receipt_id)
 SELECT jsonb_build_object(
  'order',(to_jsonb(po)-'approval_snapshot')||jsonb_build_object('created_by_name',(SELECT full_name FROM public.users WHERE auth_id=po.created_by LIMIT 1),'store_approved_by_name',(SELECT full_name FROM public.users WHERE auth_id=po.store_approved_by LIMIT 1),'brand_approved_by_name',(SELECT full_name FROM public.users WHERE auth_id=po.brand_approved_by LIMIT 1),'supplier',(SELECT jsonb_build_object('id',s.id,'supplier_name',s.supplier_name,'email',s.email,'phone',s.phone) FROM public.inventory_suppliers s WHERE s.id=po.supplier_id),'store',(SELECT jsonb_build_object('id',s.id,'name',s.name) FROM public.restaurants s WHERE s.id=po.restaurant_id)),
  'can_urgent_approve',public.can_urgent_approve_inventory_order(po.restaurant_id),
  'can_receive_and_confirm',public.can_receive_and_confirm_inventory_receipt(po.restaurant_id),
  'can_finalize_receipt',public.can_receive_and_confirm_inventory_receipt(po.restaurant_id) OR po.commercial_terms->>'approval_policy_version'='3' AND (public.can_create_inventory_purchase_order(po.restaurant_id) OR public.can_verify_inventory_receipt(po.restaurant_id)),
  'lines',COALESCE((SELECT jsonb_agg((to_jsonb(l)-'recommendation_snapshot')||jsonb_build_object('product',jsonb_build_object('name',COALESCE(l.recommendation_snapshot->>'product_name',p.name)),'product_code',COALESCE(l.recommendation_snapshot->>'product_code',p.product_code),'cumulative_quantity_base',COALESCE(a.qty,0),'remaining_quantity_base',greatest(l.ordered_quantity_base-l.cancelled_quantity_base-COALESCE(a.qty,0),0),'supplier_item',jsonb_build_object('order_unit_quantity_base',COALESCE(l.order_unit_quantity_base_snapshot,NULLIF(l.ordered_quantity_base,0)/NULLIF(l.ordered_quantity_unit,0),1))) ORDER BY COALESCE((l.recommendation_snapshot->>'line_position')::integer,0),l.id) FROM public.inventory_purchase_order_lines l JOIN public.inventory_products p ON p.id=l.product_id LEFT JOIN accepted a ON a.purchase_order_line_id=l.id WHERE l.purchase_order_id=po.id),'[]'),
  'receipts',COALESCE((SELECT jsonb_agg(to_jsonb(r)||jsonb_build_object('line_details',COALESCE(l.rows,'[]')) ORDER BY r.created_at DESC,r.id DESC) FROM (SELECT * FROM receipt_page ORDER BY created_at DESC,id DESC LIMIT 20) r LEFT JOIN receipt_lines l ON l.receipt_id=r.id),'[]'),
  'receipts_has_more',(SELECT count(*)>20 FROM receipt_page),
  'documents',COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.snapshot_version DESC) FROM (SELECT * FROM public.inventory_purchase_documents WHERE purchase_order_id=po.id ORDER BY snapshot_version DESC LIMIT 20) d),'[]'),
  'approval_events',COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.created_at DESC,e.id) FROM (SELECT * FROM public.inventory_purchase_approval_events WHERE purchase_order_id=po.id ORDER BY created_at DESC,id DESC LIMIT 100) e),'[]')) INTO result;
 RETURN result;
END $$;
-- Office validates each actor against native grants; POS checks the actual brand/entity again.
CREATE FUNCTION public.procurement_approval_inbox_batch(p_scopes jsonb,p_query jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE result jsonb;lim integer:=greatest(1,least(50,COALESCE((p_query->>'limit')::integer,50)));
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 IF jsonb_typeof(p_scopes) IS DISTINCT FROM 'array' OR jsonb_array_length(p_scopes)>100 THEN RAISE EXCEPTION 'PROCUREMENT_BATCH_LIMIT'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_scopes) AS s(store_id uuid,brand_id uuid,tax_entity_id uuid,actor jsonb)
 LEFT JOIN public.restaurants r ON r.id=s.store_id AND r.brand_id=s.brand_id AND r.tax_entity_id=s.tax_entity_id AND r.is_active
 WHERE r.id IS NULL OR s.actor->>'system' IS DISTINCT FROM 'office' OR s.actor->>'store_id' IS DISTINCT FROM s.store_id::text
 OR s.actor->>'can_read' IS DISTINCT FROM 'true' OR NULLIF(s.actor->>'subject_id','') IS NULL)
 OR (SELECT count(DISTINCT s->>'store_id') FROM jsonb_array_elements(p_scopes) s)<>jsonb_array_length(p_scopes)
 THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 WITH scopes AS MATERIALIZED(SELECT * FROM jsonb_to_recordset(p_scopes) AS s(store_id uuid,actor jsonb)),
 people AS MATERIALIZED(SELECT rr.restaurant_id,jsonb_object_agg(rr.system||':'||rr.subject_id,rr.person_id) identities
 FROM public.procurement_role_roster rr WHERE rr.restaurant_id=ANY((SELECT array_agg(store_id) FROM scopes)::uuid[]) AND rr.valid_from<=now() AND rr.valid_until>now()
 GROUP BY rr.restaurant_id),
 actors AS MATERIALIZED(SELECT s.store_id,s.actor||jsonb_build_object('identity_people',COALESCE(p.identities,'{}'),'person_id',p.identities->((s.actor->>'system')||':'||(s.actor->>'subject_id'))) actor FROM scopes s LEFT JOIN people p ON p.restaurant_id=s.store_id),
 scoped_requests AS MATERIALIZED(SELECT r AS request FROM public.inventory_purchase_requests r WHERE r.restaurant_id=ANY((SELECT array_agg(store_id) FROM scopes)::uuid[]) AND r.status IN ('submitted','brand_review','office_review','senior_review')),
 pending AS MATERIALIZED(SELECT (r.request).*,r.request,a.actor,CASE WHEN COALESCE(pol.enabled,false) THEN public.procurement_allowed_actions(r.request,a.actor) ELSE '[]'::jsonb END actions FROM scoped_requests r JOIN actors a ON a.store_id=(r.request).restaurant_id LEFT JOIN public.procurement_store_policies pol ON pol.restaurant_id=(r.request).restaurant_id),
 page AS(SELECT * FROM pending r WHERE public.procurement_inbox_stage(r.request,r.actor)
 AND(NULLIF(p_query->>'request_before','') IS NULL OR(COALESCE(r.submitted_at,r.created_at),r.id)>((p_query->>'request_before')::timestamptz,(p_query->>'request_before_id')::uuid))
 ORDER BY COALESCE(submitted_at,created_at),id LIMIT lim+1)
 SELECT jsonb_build_object('contract_version',2,'read_contract','approval_inbox','request_sort','submitted',
 'requests',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',p.id,'restaurant_id',p.restaurant_id,'office_store_id',p.actor->>'office_store_id',
  'store_name',p.actor->>'store_name','request_no',p.request_no,'status',p.status,'row_version',p.row_version,'submitted_at',COALESCE(p.submitted_at,p.created_at),'created_at',p.created_at,
  'approval_policy_version',p.approval_policy_version,'allowed_actions',p.actions) ORDER BY COALESCE(p.submitted_at,p.created_at),p.id)
  FROM(SELECT * FROM page ORDER BY COALESCE(submitted_at,created_at),id LIMIT lim)p),'[]'),
 'request_has_more',(SELECT count(*)>lim FROM page),
 'approval_counts',(SELECT jsonb_build_object('pending',count(*),'actionable',count(*) FILTER(WHERE actions ?| ARRAY['store_approve','brand_approve','office_approve','senior_approve']),
 'blocked',count(*) FILTER(WHERE public.procurement_inbox_stage(r.request,r.actor)
  AND NOT(actions ?| ARRAY['store_approve','brand_approve','office_approve','senior_approve']))) FROM pending r)) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_approval_inbox_batch(jsonb,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.procurement_approval_inbox_batch(jsonb,jsonb) TO service_role;

ALTER FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) RENAME TO procurement_pre_inbox_command;
REVOKE ALL ON FUNCTION public.procurement_pre_inbox_command(uuid,text,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.procurement_command(p_store_id uuid,p_action text,p_record_id uuid,p_expected_version integer,p_idempotency_key text,p_payload jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;version integer;
BEGIN
 IF p_action IN ('adjust_request','store_approve','office_approve','return_request') THEN
  actor:=public.procurement_actor(p_store_id,p_office_actor);
  SELECT approval_policy_version INTO version FROM public.inventory_purchase_requests WHERE id=p_record_id AND restaurant_id=p_store_id;
  IF version=3 AND actor->>'role' IN ('brand_admin','brand_manager') THEN RAISE EXCEPTION 'PROCUREMENT_APPROVAL_STAGE_REMOVED'; END IF;
 END IF;
 RETURN public.procurement_pre_inbox_command(p_store_id,p_action,p_record_id,p_expected_version,p_idempotency_key,p_payload,p_office_actor);
END $$;
REVOKE ALL ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) TO authenticated,service_role;

DO $$ BEGIN
 IF position('submitted_sort' IN pg_get_functiondef('public.procurement_workspace_page_core(uuid,jsonb,jsonb)'::regprocedure))=0
 OR (SELECT count(*) FROM pg_trigger WHERE tgname LIKE '%_live_%' AND tgrelid='public.inventory_purchase_requests'::regclass)<>3
 OR has_function_privilege('authenticated','public.procurement_actor(uuid,jsonb)','EXECUTE')
 THEN RAISE EXCEPTION 'PROCUREMENT_INBOX_CONTRACT_INVALID'; END IF;
END $$;
COMMIT;
