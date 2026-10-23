-- Buyer readiness is read in sets, independently of the authority to review.
-- production-gate: self-verifying
BEGIN;

CREATE FUNCTION public.procurement_buyer_readiness(p_request_ids uuid[])
RETURNS TABLE(request_id uuid, approval_blockers jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
 WITH requests AS MATERIALIZED (
   SELECT r.id,r.restaurant_id,r.requested_delivery_date,r.approval_policy_version,
     r.store_approved_actor,r.brand_approved_actor,r.brand_approval_hash,r.purchase_category,r.purchase_channel,
     p.max_price_increase_percent FROM public.inventory_purchase_requests r
   LEFT JOIN public.procurement_store_policies p ON p.restaurant_id=r.restaurant_id
   WHERE r.id=ANY(p_request_ids) AND r.status='office_review'
 ), requested AS MATERIALIZED (
   SELECT l.id,l.request_id,l.product_id,l.quantity_base,l.specification_snapshot,l.receipt_classification,
     l.preferred_supplier_id,l.estimated_unit_price,l.estimated_conversion,l.estimated_tax_rate,r.restaurant_id
   FROM public.inventory_purchase_request_lines l
   JOIN requests r ON r.id=l.request_id WHERE l.active
 ), quotes AS MATERIALIZED (
   SELECT q.id,q.request_id,q.supplier_id,q.valid_until,q.delivery_date,q.selected,q.archived
   FROM public.procurement_quotes q JOIN requests r ON r.id=q.request_id
 ), selected_lines AS MATERIALIZED (
   SELECT l.id,l.request_line_id,l.quantity_base,l.unit_price,l.conversion_snapshot,l.tax_rate,l.reference_unit_price,
     q.request_id,q.supplier_id,q.archived,q.delivery_date FROM public.procurement_quote_lines l
   JOIN quotes q ON q.id=l.quote_id WHERE q.selected
 ), quote_counts AS (
   SELECT q.request_id,count(*) FILTER(WHERE q.selected) selected, count(*) FILTER(WHERE NOT q.archived) registered,
     bool_or(q.selected AND q.valid_until<(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date) expired
   FROM quotes q GROUP BY q.request_id
 ), quantities AS (
   SELECT l.request_id,l.request_line_id,sum(l.quantity_base) qty FROM selected_lines l
   WHERE NOT l.archived GROUP BY l.request_id,l.request_line_id
 ), coverage AS MATERIALIZED (
   SELECT l.request_id,count(*)>0 AND bool_and(l.quantity_base=COALESCE(q.qty,0)) complete
   FROM requested l LEFT JOIN quantities q ON q.request_id=l.request_id AND q.request_line_id=l.id GROUP BY l.request_id
 ), comparisons AS (
   SELECT q.request_id,l.request_line_id,count(DISTINCT q.supplier_id) suppliers
   FROM public.procurement_quote_lines l JOIN quotes q ON q.id=l.quote_id
   WHERE NOT q.archived AND q.valid_until>=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
   GROUP BY q.request_id,l.request_line_id
 ), products AS MATERIALIZED (SELECT DISTINCT restaurant_id,product_id FROM requested),
 history AS (
   SELECT rr.restaurant_id,l.product_id,count(*) n FROM public.inventory_receipt_lines l
   JOIN public.inventory_receipts rr ON rr.id=l.receipt_id
   JOIN products p ON p.restaurant_id=rr.restaurant_id AND p.product_id=l.product_id
   WHERE rr.status='confirmed' AND l.accepted_quantity_base>0 GROUP BY rr.restaurant_id,l.product_id
 ), comparison_required AS (
   SELECT r.id request_id,bool_or((l.reference_unit_price<=0 OR h.n IS NULL
     OR (r.max_price_increase_percent IS NOT NULL AND l.unit_price>l.reference_unit_price*(1+r.max_price_increase_percent/100)))
     AND COALESCE(c.suppliers,0)<2) missing
   FROM selected_lines l JOIN requested rl ON rl.request_id=l.request_id AND rl.id=l.request_line_id
   JOIN requests r ON r.id=l.request_id
   LEFT JOIN history h ON h.restaurant_id=r.restaurant_id AND h.product_id=rl.product_id
   LEFT JOIN comparisons c ON c.request_id=r.id AND c.request_line_id=rl.id GROUP BY r.id
 ), quoted_terms AS (
   SELECT l.request_id,l.request_line_id,jsonb_agg(jsonb_build_object('supplier',l.supplier_id,'qty',l.quantity_base,
     'price_base',round(l.unit_price/l.conversion_snapshot,8),'vat',l.tax_rate,'delivery',l.delivery_date)
     ORDER BY l.supplier_id,l.id) terms FROM selected_lines l
   JOIN requests r ON r.id=l.request_id AND r.approval_policy_version=2
   WHERE NOT l.archived GROUP BY l.request_id,l.request_line_id
 ), brand_lines AS (
   SELECT l.request_id,jsonb_agg(jsonb_build_object('id',l.id,'product_id',l.product_id,
     'quantity_base',l.quantity_base,'specification_snapshot',l.specification_snapshot,
     'receipt_classification',l.receipt_classification,'commercial',CASE WHEN c.complete THEN q.terms
     ELSE jsonb_build_array(jsonb_build_object('supplier',l.preferred_supplier_id,'qty',l.quantity_base,
       'price_base',round(l.estimated_unit_price/NULLIF(l.estimated_conversion,0),8),
       'vat',l.estimated_tax_rate,'delivery',r.requested_delivery_date)) END) ORDER BY l.id) terms
   FROM requested l JOIN requests r ON r.id=l.request_id AND r.approval_policy_version=2
   LEFT JOIN coverage c ON c.request_id=r.id LEFT JOIN quoted_terms q ON q.request_id=l.request_id AND q.request_line_id=l.id GROUP BY l.request_id
 )
 SELECT r.id,to_jsonb(array_remove(ARRAY[
   CASE WHEN r.approval_policy_version=3 AND r.store_approved_actor IS NULL THEN 'PROCUREMENT_STORE_APPROVAL_REQUIRED' END,
   CASE WHEN r.approval_policy_version=2 AND (r.brand_approved_actor IS NULL OR r.brand_approval_hash IS DISTINCT FROM
     encode(extensions.digest(convert_to(jsonb_build_object('date',r.requested_delivery_date,'category',r.purchase_category,
       'channel',r.purchase_channel,'lines',b.terms)::text,'UTF8'),'sha256'),'hex')) THEN 'PROCUREMENT_BRAND_APPROVAL_REQUIRED' END,
   CASE WHEN COALESCE(q.selected,0)=0 THEN CASE WHEN COALESCE(q.registered,0)>0 THEN 'PROCUREMENT_QUOTE_SELECTION_REQUIRED' ELSE 'PROCUREMENT_QUOTE_REQUIRED' END END,
   CASE WHEN q.expired THEN 'PROCUREMENT_QUOTE_EXPIRED' END,
   CASE WHEN COALESCE(q.selected,0)>0 AND NOT COALESCE(c.complete,false) THEN 'PROCUREMENT_QUOTE_COVERAGE_REQUIRED' END,
   CASE WHEN x.missing THEN 'PROCUREMENT_COMPARATIVE_QUOTES_REQUIRED' END
 ]::text[],NULL))
 FROM requests r LEFT JOIN quote_counts q ON q.request_id=r.id
 LEFT JOIN coverage c ON c.request_id=r.id LEFT JOIN comparison_required x ON x.request_id=r.id
 LEFT JOIN brand_lines b ON b.request_id=r.id
$$;
REVOKE ALL ON FUNCTION public.procurement_buyer_readiness(uuid[]) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.procurement_approval_state(p_blockers jsonb,p_actions jsonb,p_enabled boolean)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 WITH blockers AS (SELECT CASE WHEN NOT COALESCE(p_enabled,false) THEN '["PROCUREMENT_NOT_ENABLED"]'::jsonb
   WHEN NOT COALESCE(p_actions ?| ARRAY['store_approve','brand_approve','office_approve','senior_approve'],false)
     THEN '["PROCUREMENT_APPROVAL_NOT_PERMITTED"]'::jsonb
   ELSE COALESCE(p_blockers,'[]'::jsonb) END value)
 SELECT jsonb_build_object('approval_ready',jsonb_array_length(value)=0,'approval_blockers',value,
   'next_action',CASE WHEN value ? 'PROCUREMENT_QUOTE_REQUIRED' OR value ? 'PROCUREMENT_QUOTE_EXPIRED'
       OR value ? 'PROCUREMENT_COMPARATIVE_QUOTES_REQUIRED' THEN 'save_quote'
     WHEN value ? 'PROCUREMENT_QUOTE_COVERAGE_REQUIRED' OR value ? 'PROCUREMENT_QUOTE_SELECTION_REQUIRED' THEN 'select_quote'
     WHEN jsonb_array_length(value)=0 THEN 'review_request' ELSE 'resolve_blocker' END) FROM blockers
$$;
REVOKE ALL ON FUNCTION public.procurement_approval_state(jsonb,jsonb,boolean) FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.procurement_approval_inbox_batch(p_scopes jsonb,p_query jsonb DEFAULT '{}')
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
 candidates AS MATERIALIZED(SELECT r.request,a.actor,pol.enabled FROM scoped_requests r
 JOIN actors a ON a.store_id=(r.request).restaurant_id LEFT JOIN public.procurement_store_policies pol ON pol.restaurant_id=(r.request).restaurant_id
 WHERE public.procurement_inbox_stage(r.request,a.actor)),
 readiness AS MATERIALIZED(SELECT * FROM public.procurement_buyer_readiness((SELECT array_agg((request).id) FROM candidates))),
 pending AS MATERIALIZED(SELECT (c.request).*,c.request,c.actor,public.procurement_allowed_actions(c.request,c.actor) actions,
 public.procurement_approval_state(r.approval_blockers,public.procurement_allowed_actions(c.request,c.actor),c.enabled) approval
 FROM candidates c LEFT JOIN readiness r ON r.request_id=(c.request).id),
 page AS(SELECT * FROM pending r WHERE public.procurement_inbox_stage(r.request,r.actor)
 AND(NULLIF(p_query->>'request_before','') IS NULL OR(COALESCE(r.submitted_at,r.created_at),r.id)>((p_query->>'request_before')::timestamptz,(p_query->>'request_before_id')::uuid))
 ORDER BY COALESCE(submitted_at,created_at),id LIMIT lim+1)
 SELECT jsonb_build_object('contract_version',2,'approval_readiness_version',1,'read_contract','approval_inbox','request_sort','submitted',
 'requests',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',p.id,'restaurant_id',p.restaurant_id,'office_store_id',p.actor->>'office_store_id',
  'store_name',p.actor->>'store_name','request_no',p.request_no,'status',p.status,'row_version',p.row_version,'submitted_at',COALESCE(p.submitted_at,p.created_at),'created_at',p.created_at,
  'approval_policy_version',p.approval_policy_version,'updated_at',p.updated_at,'allowed_actions',p.actions)||p.approval ORDER BY COALESCE(p.submitted_at,p.created_at),p.id)
  FROM(SELECT * FROM page ORDER BY COALESCE(submitted_at,created_at),id LIMIT lim)p),'[]'),
 'request_has_more',(SELECT count(*)>lim FROM page),
 'approval_counts',(SELECT jsonb_build_object('pending',count(*),'actionable',count(*) FILTER(WHERE (approval->>'approval_ready')::boolean),
 'blocked',count(*) FILTER(WHERE NOT (approval->>'approval_ready')::boolean)) FROM pending r)) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_approval_inbox_batch(jsonb,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.procurement_approval_inbox_batch(jsonb,jsonb) TO service_role;


-- Wrap the existing scoped reader, preserving historical policy/receiving data.
ALTER FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) RENAME TO procurement_pre_readiness_page;
REVOKE ALL ON FUNCTION public.procurement_pre_readiness_page(uuid,jsonb,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.procurement_workspace_page(p_store_id uuid,p_query jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE result jsonb;actor jsonb;checks jsonb;counts jsonb;
BEGIN
 result:=public.procurement_pre_readiness_page(p_store_id,p_query,p_office_actor);
 IF NOT(result ? 'requests') THEN RETURN result; END IF;
 actor:=public.procurement_inbox_actor(p_store_id,p_office_actor);
 IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) THEN RETURN result; END IF;
 WITH requests AS MATERIALIZED (SELECT r.* FROM public.inventory_purchase_requests r
   WHERE r.restaurant_id=p_store_id AND r.status='office_review'),
 readiness AS MATERIALIZED (SELECT * FROM public.procurement_buyer_readiness((SELECT array_agg(id) FROM requests))),
 states AS (SELECT r.id,public.procurement_approval_state(c.approval_blockers,
   public.procurement_allowed_actions(r,actor),COALESCE((result->>'enabled')::boolean,false)) state
   FROM requests r LEFT JOIN readiness c ON c.request_id=r.id)
 SELECT COALESCE(jsonb_object_agg(id::text,state),'{}'),jsonb_build_object('pending',count(*),
   'actionable',count(*) FILTER(WHERE (state->>'approval_ready')::boolean),
   'blocked',count(*) FILTER(WHERE NOT (state->>'approval_ready')::boolean)) INTO checks,counts FROM states;
 SELECT jsonb_set(result,'{requests}',COALESCE(jsonb_agg(row||COALESCE(checks->(row->>'id'),'{}') ORDER BY n),'[]'))
 INTO result FROM jsonb_array_elements(result->'requests') WITH ORDINALITY a(row,n);
 IF result->'request_detail'->>'id' IS NOT NULL AND checks ? (result->'request_detail'->>'id') THEN
   result:=jsonb_set(result,'{request_detail}',result->'request_detail'||(checks->(result->'request_detail'->>'id')));
 END IF;
 RETURN result||jsonb_build_object('approval_counts',counts,'approval_readiness_version',1);
END $$;
REVOKE ALL ON FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) TO authenticated,service_role;

DO $$ BEGIN
 IF has_function_privilege('authenticated','public.procurement_buyer_readiness(uuid[])','EXECUTE')
 OR has_function_privilege('anon','public.procurement_approval_inbox_batch(jsonb,jsonb)','EXECUTE')
 OR position('approval_ready' IN pg_get_functiondef('public.procurement_approval_inbox_batch(jsonb,jsonb)'::regprocedure))=0
 THEN RAISE EXCEPTION 'PROCUREMENT_READINESS_BOUNDARY_INVALID'; END IF;
END $$;
COMMIT;
