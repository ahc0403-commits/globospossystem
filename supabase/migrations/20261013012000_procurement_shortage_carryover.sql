BEGIN;
-- production-gate: self-verifying
CREATE FUNCTION public.procurement_shortages(p_store_id uuid,p_query jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;result jsonb;rid uuid:=NULLIF(p_query->>'request_id','')::uuid;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 IF rid IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.inventory_purchase_requests WHERE id=rid AND restaurant_id=p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
 WITH orders AS MATERIALIZED(SELECT po.id,po.supplier_id,po.purchase_order_no FROM public.inventory_purchase_orders po
  WHERE po.restaurant_id=p_store_id AND po.workflow_version=2 AND po.status IN ('ordered','partially_received')
   AND EXISTS(SELECT 1 FROM public.inventory_receipts r WHERE r.purchase_order_id=po.id AND r.status='confirmed')),
 accepted AS(SELECT l.purchase_order_line_id,sum(l.accepted_quantity_base) qty FROM public.inventory_receipt_lines l
  JOIN public.inventory_receipts r ON r.id=l.receipt_id AND r.status='confirmed' JOIN orders o ON o.id=r.purchase_order_id GROUP BY l.purchase_order_line_id),
 reserved AS(SELECT a.original_order_line_id,sum(a.quantity_base) qty,sum(a.quantity_base) FILTER(WHERE rl.request_id=rid) own
  FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_request_lines rl ON rl.id=a.request_line_id
  JOIN public.inventory_purchase_order_lines ol ON ol.id=a.original_order_line_id JOIN orders o ON o.id=ol.purchase_order_id WHERE a.status='reserved' GROUP BY a.original_order_line_id),
 page AS(SELECT ol.id original_order_line_id,o.id original_order_id,o.purchase_order_no,o.supplier_id,s.supplier_name,p.id product_id,p.name product_name,p.product_code,
  p.stock_unit,p.base_unit,p.base_unit_factor conversion,ol.order_unit,ol.order_unit_quantity_base_snapshot,
  greatest(0,ol.ordered_quantity_base-ol.cancelled_quantity_base-COALESCE(a.qty,0)-COALESCE(r.qty,0)+COALESCE(r.own,0)) shortage_quantity_base,
  COALESCE(r.own,0) reserved_quantity_base
  FROM orders o JOIN public.inventory_purchase_order_lines ol ON ol.purchase_order_id=o.id JOIN public.inventory_products p ON p.id=ol.product_id AND p.is_active AND p.is_orderable
  JOIN public.inventory_suppliers s ON s.id=o.supplier_id LEFT JOIN accepted a ON a.purchase_order_line_id=ol.id LEFT JOIN reserved r ON r.original_order_line_id=ol.id
  WHERE (NOT COALESCE((p_query->>'owned_shortages_only')::boolean,false) OR COALESCE(r.own,0)>0)
   AND (NULLIF(p_query->>'shortage_after','') IS NULL OR ol.id>(p_query->>'shortage_after')::uuid)
   AND ol.ordered_quantity_base-ol.cancelled_quantity_base-COALESCE(a.qty,0)-COALESCE(r.qty,0)+COALESCE(r.own,0)>0 ORDER BY ol.id LIMIT 201)
 SELECT jsonb_build_object('rows',COALESCE((SELECT jsonb_agg(to_jsonb(p) ORDER BY original_order_line_id) FROM (SELECT * FROM page ORDER BY original_order_line_id LIMIT 200) p),'[]'),
  'has_more',(SELECT count(*)>200 FROM page)) INTO result;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_shortages(uuid,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_shortages(uuid,jsonb,jsonb) TO authenticated,service_role;

-- Public command keeps the existing Office/role bridge, with policy-3 guards and
-- reservations committed in the same transaction as PR/PO creation.
ALTER FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) RENAME TO procurement_pre_carryover_command;
REVOKE ALL ON FUNCTION public.procurement_pre_carryover_command(uuid,text,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.procurement_command(p_store_id uuid,p_action text,p_record_id uuid,p_expected_version integer,p_idempotency_key text,p_payload jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;req public.inventory_purchase_requests%rowtype;prior public.procurement_command_results%rowtype;
 result jsonb;h text;actor_key text;rid uuid;poid uuid;sources jsonb;report public.procurement_receipt_reports%rowtype;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);actor_key:=(actor->>'system')||':'||(actor->>'subject_id');
 IF NULLIF(btrim(p_idempotency_key),'') IS NULL OR length(p_idempotency_key)>160 THEN RAISE EXCEPTION 'PROCUREMENT_IDEMPOTENCY_KEY_REQUIRED'; END IF;
 h:=encode(extensions.digest(convert_to(jsonb_build_object('action',p_action,'record',p_record_id,'version',p_expected_version,'payload',p_payload)::text,'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text||':'||p_idempotency_key,0));
 SELECT * INTO prior FROM public.procurement_command_results WHERE restaurant_id=p_store_id AND idempotency_key=p_idempotency_key;
 IF FOUND AND p_action<>'assign_principal' THEN
  IF prior.actor_key<>actor_key OR prior.payload_hash<>h THEN RAISE EXCEPTION 'PROCUREMENT_RETRY_MISMATCH'; END IF; RETURN prior.result;
 END IF;
 IF p_action='mark_receipt_report_sent' THEN
  SELECT * INTO report FROM public.procurement_receipt_reports WHERE receipt_id=p_record_id AND restaurant_id=p_store_id FOR UPDATE;
  IF NOT FOUND OR report.file_hash IS NULL OR p_payload->>'file_hash' IS DISTINCT FROM report.file_hash THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_REQUIRED'; END IF;
  IF NULLIF(btrim(p_payload->>'channel'),'') IS NULL OR NULLIF(btrim(p_payload->>'delivery_reference'),'') IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_DELIVERY_REFERENCE_REQUIRED'; END IF;
  UPDATE public.procurement_receipt_reports SET sent_at=now(),sent_actor=actor,channel=p_payload->>'channel',delivery_reference=p_payload->>'delivery_reference' WHERE receipt_id=p_record_id RETURNING to_jsonb(procurement_receipt_reports) INTO result;
  INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,previous_state,next_state,reason) VALUES(p_store_id,p_record_id,p_action,actor,to_jsonb(report),result,p_payload->>'delivery_reference');
  INSERT INTO public.procurement_command_results VALUES(p_store_id,p_idempotency_key,actor_key,h,result,now());RETURN result;
 END IF;
 IF p_record_id IS NOT NULL AND p_action IN ('adjust_request','store_approve','brand_approve','office_approve','senior_approve','submit_request','issue_po','save_request','cancel_request','return_request') THEN
  SELECT * INTO req FROM public.inventory_purchase_requests WHERE id=p_record_id AND restaurant_id=p_store_id FOR UPDATE;
  IF req.approval_policy_version=3 AND p_action IN ('adjust_request','store_approve','office_approve') THEN
   IF public.procurement_same_person(req.created_actor,actor,p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_SELF_APPROVAL_FORBIDDEN'; END IF;
   IF p_action='office_approve' AND public.procurement_same_person(req.store_approved_actor,actor,p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_DISTINCT_APPROVER_REQUIRED'; END IF;
  END IF;
  IF req.approval_policy_version=3 AND p_action IN ('brand_approve','senior_approve') THEN RAISE EXCEPTION 'PROCUREMENT_APPROVAL_STAGE_REMOVED'; END IF;
 END IF;
 IF p_action IN ('create_request','save_request') THEN
  IF jsonb_typeof(p_payload->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'lines') NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'PROCUREMENT_LINES_REQUIRED'; END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('position',l.ordinality,'product_id',l.value->>'product_id','source',s)),'[]') INTO sources
   FROM jsonb_array_elements(p_payload->'lines') WITH ORDINALITY l(value,ordinality) CROSS JOIN LATERAL jsonb_array_elements(COALESCE(l.value->'shortage_sources','[]')) s;
  IF jsonb_array_length(sources)>200 THEN RAISE EXCEPTION 'PROCUREMENT_SHORTAGE_LIMIT_EXCEEDED'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(sources) x WHERE (x->'source'->>'quantity_base')::numeric IS NULL OR (x->'source'->>'quantity_base')::numeric<=0 OR (x->'source'->>'quantity_base')::numeric::text IN ('NaN','Infinity','-Infinity') OR (x->'source'->>'quantity_base')::numeric<>round((x->'source'->>'quantity_base')::numeric,3)) THEN RAISE EXCEPTION 'PROCUREMENT_SHORTAGE_QUANTITY_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(sources) x GROUP BY x->>'position',x->'source'->>'original_order_line_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'PROCUREMENT_SHORTAGE_DUPLICATE'; END IF;
  PERFORM 1 FROM public.inventory_purchase_orders po WHERE po.restaurant_id=p_store_id AND po.id IN(SELECT ol.purchase_order_id FROM public.inventory_purchase_order_lines ol JOIN jsonb_array_elements(sources) x ON ol.id=(x->'source'->>'original_order_line_id')::uuid) ORDER BY po.id FOR UPDATE;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(sources) x LEFT JOIN public.inventory_purchase_order_lines ol ON ol.id=(x->'source'->>'original_order_line_id')::uuid LEFT JOIN public.inventory_purchase_orders po ON po.id=ol.purchase_order_id WHERE ol.id IS NULL OR po.restaurant_id<>p_store_id OR po.workflow_version<>2 OR po.status NOT IN ('ordered','partially_received') OR po.id NOT IN(SELECT DISTINCT purchase_order_id FROM public.inventory_receipts WHERE restaurant_id=p_store_id AND status='confirmed') OR ol.product_id::text<>x->>'product_id') THEN RAISE EXCEPTION 'PROCUREMENT_SHORTAGE_SOURCE_INVALID'; END IF;
  IF p_action='save_request' THEN UPDATE public.procurement_shortage_allocations a SET status='released',updated_at=now() FROM public.inventory_purchase_request_lines l WHERE l.id=a.request_line_id AND l.request_id=p_record_id AND a.status='reserved'; END IF;
 END IF;
 IF p_action IN ('submit_request','office_approve','issue_po') THEN
  PERFORM 1 FROM public.inventory_purchase_orders po WHERE po.restaurant_id=p_store_id AND po.id IN(SELECT ol.purchase_order_id FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id JOIN public.inventory_purchase_order_lines ol ON ol.id=a.original_order_line_id WHERE l.request_id=p_record_id AND a.status='reserved') ORDER BY po.id FOR UPDATE;
  IF EXISTS(WITH source_ids AS MATERIALIZED(SELECT DISTINCT a.original_order_line_id FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id WHERE a.restaurant_id=p_store_id AND l.request_id=p_record_id AND a.status='reserved'),
   accepted AS(SELECT l.purchase_order_line_id,sum(l.accepted_quantity_base) qty FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id AND r.status='confirmed' JOIN source_ids si ON si.original_order_line_id=l.purchase_order_line_id GROUP BY l.purchase_order_line_id),
   reserved AS(SELECT a.original_order_line_id,sum(a.quantity_base) qty FROM public.procurement_shortage_allocations a JOIN source_ids si ON si.original_order_line_id=a.original_order_line_id WHERE a.status='reserved' GROUP BY a.original_order_line_id)
   SELECT 1 FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id JOIN public.inventory_purchase_order_lines ol ON ol.id=a.original_order_line_id LEFT JOIN accepted ac ON ac.purchase_order_line_id=ol.id JOIN reserved rv ON rv.original_order_line_id=ol.id WHERE l.request_id=p_record_id AND a.status='reserved' AND ol.ordered_quantity_base-ol.cancelled_quantity_base-COALESCE(ac.qty,0)<rv.qty) THEN RAISE EXCEPTION 'PROCUREMENT_SHORTAGE_CHANGED'; END IF;
 END IF;
 result:=public.procurement_pre_carryover_command(p_store_id,p_action,p_record_id,p_expected_version,p_idempotency_key,p_payload,p_office_actor);
 rid:=COALESCE((result->>'id')::uuid,p_record_id);
 IF p_action IN ('create_request','save_request') THEN
  INSERT INTO public.procurement_shortage_allocations(restaurant_id,original_order_line_id,request_line_id,quantity_base,status)
   SELECT p_store_id,(x->'source'->>'original_order_line_id')::uuid,l.id,(x->'source'->>'quantity_base')::numeric,'reserved'
   FROM jsonb_array_elements(sources) x JOIN public.inventory_purchase_request_lines l ON l.request_id=rid AND l.active AND l.line_position=(x->>'position')::integer;
  IF EXISTS(WITH source_ids AS MATERIALIZED(SELECT DISTINCT a.original_order_line_id FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id WHERE a.restaurant_id=p_store_id AND l.request_id=rid AND a.status='reserved'),
   accepted AS(SELECT l.purchase_order_line_id,sum(l.accepted_quantity_base) qty FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id AND r.status='confirmed' JOIN source_ids si ON si.original_order_line_id=l.purchase_order_line_id GROUP BY l.purchase_order_line_id),
   reserved AS(SELECT a.original_order_line_id,sum(a.quantity_base) qty FROM public.procurement_shortage_allocations a JOIN source_ids si ON si.original_order_line_id=a.original_order_line_id WHERE a.status='reserved' GROUP BY a.original_order_line_id)
   SELECT 1 FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id JOIN public.inventory_purchase_order_lines ol ON ol.id=a.original_order_line_id LEFT JOIN accepted ac ON ac.purchase_order_line_id=ol.id JOIN reserved rv ON rv.original_order_line_id=ol.id WHERE l.request_id=rid AND a.status='reserved' AND ol.ordered_quantity_base-ol.cancelled_quantity_base-COALESCE(ac.qty,0)<rv.qty) THEN RAISE EXCEPTION 'PROCUREMENT_SHORTAGE_CHANGED'; END IF;
  IF EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines l JOIN public.procurement_shortage_allocations a ON a.request_line_id=l.id AND a.status='reserved' JOIN public.inventory_purchase_order_lines ol ON ol.id=a.original_order_line_id JOIN public.inventory_purchase_orders po ON po.id=ol.purchase_order_id WHERE l.request_id=rid AND l.active GROUP BY l.id,l.quantity_base,l.preferred_supplier_id HAVING sum(a.quantity_base)>l.quantity_base OR bool_or(l.preferred_supplier_id IS DISTINCT FROM po.supplier_id)) THEN RAISE EXCEPTION 'PROCUREMENT_SHORTAGE_QUANTITY_INVALID'; END IF;
 ELSIF p_action='adjust_request' THEN
  IF EXISTS(SELECT 1 FROM public.inventory_purchase_request_lines l JOIN public.procurement_shortage_allocations a ON a.request_line_id=l.id AND a.status='reserved' WHERE l.request_id=rid GROUP BY l.id,l.quantity_base HAVING sum(a.quantity_base)>l.quantity_base) THEN RAISE EXCEPTION 'PROCUREMENT_SHORTAGE_QUANTITY_INVALID'; END IF;
 ELSIF p_action='cancel_request' THEN
  UPDATE public.procurement_shortage_allocations a SET status='released',updated_at=now() FROM public.inventory_purchase_request_lines l WHERE l.id=a.request_line_id AND l.request_id=rid AND a.status='reserved';
 ELSIF p_action='issue_po' THEN
  poid:=(result->'purchase_order'->>'id')::uuid;
  IF EXISTS(SELECT 1 FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id JOIN public.inventory_purchase_order_lines target ON target.purchase_order_id=poid AND target.recommendation_snapshot->>'request_line_id'=l.id::text JOIN public.inventory_purchase_order_lines original ON original.id=a.original_order_line_id JOIN public.inventory_purchase_orders original_po ON original_po.id=original.purchase_order_id JOIN public.inventory_purchase_orders target_po ON target_po.id=poid WHERE a.status='reserved' AND original_po.supplier_id<>target_po.supplier_id) THEN RAISE EXCEPTION 'PROCUREMENT_SHORTAGE_SUPPLIER_CHANGED'; END IF;
  IF EXISTS(SELECT 1 FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_order_lines target ON target.purchase_order_id=poid AND target.recommendation_snapshot->>'request_line_id'=a.request_line_id::text WHERE a.status='reserved' GROUP BY target.id,target.ordered_quantity_base HAVING sum(a.quantity_base)>target.ordered_quantity_base) THEN RAISE EXCEPTION 'PROCUREMENT_SHORTAGE_QUANTITY_INVALID'; END IF;
  UPDATE public.procurement_shortage_allocations a SET status='issued',target_order_line_id=target.id,updated_at=now() FROM public.inventory_purchase_order_lines target WHERE a.status='reserved' AND target.purchase_order_id=poid AND target.recommendation_snapshot->>'request_line_id'=a.request_line_id::text;
  PERFORM set_config('app.procurement_write','true',true);
  WITH transferred AS(SELECT a.original_order_line_id,sum(a.quantity_base) qty FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_order_lines target ON target.id=a.target_order_line_id WHERE target.purchase_order_id=poid AND a.status='issued' GROUP BY a.original_order_line_id)
  UPDATE public.inventory_purchase_order_lines ol SET cancelled_quantity_base=ol.cancelled_quantity_base+t.qty,transferred_quantity_base=ol.transferred_quantity_base+t.qty FROM transferred t WHERE ol.id=t.original_order_line_id;
  WITH originals AS(SELECT DISTINCT ol.purchase_order_id FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_order_lines ol ON ol.id=a.original_order_line_id JOIN public.inventory_purchase_order_lines target ON target.id=a.target_order_line_id WHERE target.purchase_order_id=poid),
  accepted AS(SELECT rl.purchase_order_line_id,sum(rl.accepted_quantity_base) qty FROM public.inventory_receipt_lines rl JOIN public.inventory_receipts r ON r.id=rl.receipt_id AND r.status='confirmed' JOIN originals o ON o.purchase_order_id=r.purchase_order_id GROUP BY rl.purchase_order_line_id),
  done AS(SELECT ol.purchase_order_id,bool_and(ol.ordered_quantity_base-ol.cancelled_quantity_base<=COALESCE(a.qty,0)) closed FROM public.inventory_purchase_order_lines ol JOIN originals o ON o.purchase_order_id=ol.purchase_order_id LEFT JOIN accepted a ON a.purchase_order_line_id=ol.id GROUP BY ol.purchase_order_id)
  UPDATE public.inventory_purchase_orders po SET status=CASE WHEN d.closed THEN 'received' ELSE 'partially_received' END,commercial_terms=po.commercial_terms||jsonb_build_object('receiving_outcome','partial_transferred'),row_version=po.row_version+1,updated_at=now() FROM done d WHERE po.id=d.purchase_order_id;
  INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,next_state,reason) SELECT p_store_id,ol.purchase_order_id,'transfer_shortage',actor,jsonb_build_object('target_purchase_order_id',poid,'allocations',jsonb_agg(to_jsonb(a))),'Unreceived balance carried to next PO' FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_order_lines ol ON ol.id=a.original_order_line_id JOIN public.inventory_purchase_order_lines target ON target.id=a.target_order_line_id WHERE target.purchase_order_id=poid GROUP BY ol.purchase_order_id;
 END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) TO authenticated,service_role;

ALTER FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) RENAME TO procurement_pre_carryover_page;
REVOKE ALL ON FUNCTION public.procurement_pre_carryover_page(uuid,jsonb,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.procurement_workspace_page(p_store_id uuid,p_query jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE result jsonb;rid uuid:=NULLIF(p_query->>'request_id','')::uuid;
BEGIN
 result:=public.procurement_pre_carryover_page(p_store_id,p_query,p_office_actor);
 IF COALESCE((p_query->>'include_shortages')::boolean,false) THEN result:=result||jsonb_build_object('shortages',public.procurement_shortages(p_store_id,p_query,p_office_actor)); END IF;
 IF rid IS NOT NULL AND result ? 'request_detail' THEN
  WITH sources AS(SELECT a.request_line_id,jsonb_agg(jsonb_build_object('original_order_line_id',a.original_order_line_id,'quantity_base',a.quantity_base,'purchase_order_no',po.purchase_order_no) ORDER BY a.id) rows FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id JOIN public.inventory_purchase_order_lines ol ON ol.id=a.original_order_line_id JOIN public.inventory_purchase_orders po ON po.id=ol.purchase_order_id WHERE l.request_id=rid AND a.status IN ('reserved','issued') GROUP BY a.request_line_id),
  enriched AS(SELECT e,COALESCE(s.rows,'[]'::jsonb) sources FROM jsonb_array_elements(result->'request_detail'->'lines') e LEFT JOIN sources s ON s.request_line_id=(e->>'id')::uuid)
  SELECT jsonb_set(result,'{request_detail,lines}',COALESCE(jsonb_agg(e||jsonb_build_object('shortage_sources',sources) ORDER BY jsonb_array_length(sources)>0 DESC,(e->>'line_position')::integer,e->>'id'),'[]')) INTO result FROM enriched;
 END IF;
 IF NULLIF(p_query->>'order_id','') IS NOT NULL THEN
  result:=result||jsonb_build_object('receipt_reports',COALESCE((SELECT jsonb_agg(to_jsonb(r)-'data' ORDER BY r.created_at DESC,r.receipt_id) FROM public.procurement_receipt_reports r JOIN jsonb_array_elements(result->'receipts') cr ON cr->>'id'=r.receipt_id::text WHERE r.restaurant_id=p_store_id),'[]'));
 END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) TO authenticated,service_role;

CREATE FUNCTION public.finalize_procurement_receipt(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE receipt jsonb;final_result jsonb;po public.inventory_purchase_orders%rowtype;rid uuid:=(p_payload->>'p_receipt_id')::uuid;
BEGIN
 SELECT * INTO po FROM public.inventory_purchase_orders WHERE id=(p_payload->>'p_purchase_order_id')::uuid;
 IF po.commercial_terms->>'approval_policy_version' IS DISTINCT FROM '3' THEN RAISE EXCEPTION 'PROCUREMENT_TWO_STAGE_RECEIPT_REQUIRED'; END IF;
 receipt:=public.submit_inventory_receipt_batch(po.id,rid,(p_payload->>'p_expected_order_version')::integer,(p_payload->>'p_expected_receipt_version')::integer,p_payload->>'p_idempotency_key',p_payload->'p_lines',p_payload->>'p_inspector_name',p_payload->>'p_statement_storage_path',p_payload->>'p_statement_number',(p_payload->>'p_statement_date')::date,p_payload->>'p_memo');
 IF receipt ? 'final_result' THEN RETURN receipt->'final_result'; END IF;
 po:=public.verify_inventory_receipt(rid,(receipt->>'row_version')::integer,p_payload->>'p_idempotency_key'||':confirm','[]','delivery_inspected');
 final_result:=jsonb_build_object('receipt_id',rid,'status','confirmed','purchase_order',jsonb_build_object('id',po.id,'row_version',po.row_version,'status',po.status,'procurement_status',po.procurement_status,'restaurant_id',po.restaurant_id),'report',public.procurement_receipt_report_data(po.restaurant_id,rid));
 UPDATE public.inventory_receipt_submission_attempts SET result=jsonb_set(inventory_receipt_submission_attempts.result,'{final_result}',final_result) WHERE receipt_id=rid AND attempt_key=p_payload->>'p_idempotency_key';
 RETURN final_result;
END $$;
REVOKE ALL ON FUNCTION public.finalize_procurement_receipt(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.finalize_procurement_receipt(jsonb) TO authenticated;
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
  'lines',COALESCE((SELECT jsonb_agg((to_jsonb(l)-'recommendation_snapshot')||jsonb_build_object('product',jsonb_build_object('name',COALESCE(l.recommendation_snapshot->>'product_name',p.name)),'product_code',COALESCE(l.recommendation_snapshot->>'product_code',p.product_code),'cumulative_quantity_base',COALESCE(a.qty,0),'remaining_quantity_base',greatest(l.ordered_quantity_base-l.cancelled_quantity_base-COALESCE(a.qty,0),0),'supplier_item',jsonb_build_object('order_unit_quantity_base',COALESCE(l.order_unit_quantity_base_snapshot,NULLIF(l.ordered_quantity_base,0)/NULLIF(l.ordered_quantity_unit,0),1))) ORDER BY COALESCE((l.recommendation_snapshot->>'line_position')::integer,0),l.id) FROM public.inventory_purchase_order_lines l JOIN public.inventory_products p ON p.id=l.product_id LEFT JOIN accepted a ON a.purchase_order_line_id=l.id WHERE l.purchase_order_id=po.id),'[]'),
  'receipts',COALESCE((SELECT jsonb_agg(to_jsonb(r)||jsonb_build_object('line_details',COALESCE(l.rows,'[]')) ORDER BY r.created_at DESC,r.id DESC) FROM (SELECT * FROM receipt_page ORDER BY created_at DESC,id DESC LIMIT 20) r LEFT JOIN receipt_lines l ON l.receipt_id=r.id),'[]'),
  'receipts_has_more',(SELECT count(*)>20 FROM receipt_page),
  'documents',COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.snapshot_version DESC) FROM (SELECT * FROM public.inventory_purchase_documents WHERE purchase_order_id=po.id ORDER BY snapshot_version DESC LIMIT 20) d),'[]'),
  'approval_events',COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.created_at DESC,e.id) FROM (SELECT * FROM public.inventory_purchase_approval_events WHERE purchase_order_id=po.id ORDER BY created_at DESC,id DESC LIMIT 100) e),'[]')) INTO result;
 RETURN result;
END $$;

ALTER FUNCTION public.procurement_document_data(uuid,text,uuid,text,jsonb) RENAME TO procurement_pre_carryover_document_data;
REVOKE ALL ON FUNCTION public.procurement_pre_carryover_document_data(uuid,text,uuid,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.procurement_document_data(p_store_id uuid,p_kind text,p_record_id uuid,p_audience text,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE result jsonb;
BEGIN
 result:=public.procurement_pre_carryover_document_data(p_store_id,p_kind,p_record_id,p_audience,p_office_actor);
 IF p_kind='pr' THEN
  WITH sources AS(SELECT a.request_line_id,sum(a.quantity_base) quantity_base,jsonb_agg(jsonb_build_object('original_order_line_id',a.original_order_line_id,'quantity_base',a.quantity_base,'purchase_order_no',po.purchase_order_no) ORDER BY a.id) rows FROM public.procurement_shortage_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id AND l.request_id=p_record_id JOIN public.inventory_purchase_order_lines ol ON ol.id=a.original_order_line_id JOIN public.inventory_purchase_orders po ON po.id=ol.purchase_order_id WHERE a.status IN ('reserved','issued') GROUP BY a.request_line_id)
  SELECT jsonb_set(result,'{data,lines}',COALESCE(jsonb_agg(e||jsonb_build_object('shortage_sources',COALESCE(s.rows,'[]'),'shortage_quantity',COALESCE(s.quantity_base,0)/NULLIF((e->>'conversion_snapshot')::numeric,0)) ORDER BY s.request_line_id IS NOT NULL DESC,(e->>'line_position')::integer,e->>'id'),'[]')) INTO result FROM jsonb_array_elements(result->'data'->'lines') e LEFT JOIN sources s ON s.request_line_id=(e->>'id')::uuid;
  result:=jsonb_set(result,'{source_hash}',to_jsonb(encode(extensions.digest(convert_to((result->'data')::text,'UTF8'),'sha256'),'hex')));
 END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_document_data(uuid,text,uuid,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_document_data(uuid,text,uuid,text,jsonb) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.get_inventory_workflow_orders(
  p_store_id uuid DEFAULT NULL, p_statuses text[] DEFAULT NULL,
  p_mine_only boolean DEFAULT false, p_offset integer DEFAULT 0, p_limit integer DEFAULT 80
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE result jsonb; v_role text := public.inventory_purchase_actor_role();
BEGIN
  IF v_role NOT IN ('admin','store_admin','brand_admin','super_admin','inventory_orderer','inventory_accounting')
     OR v_role IS NULL THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN'; END IF;
  IF p_store_id IS NOT NULL AND NOT public.can_access_inventory_workflow(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;
  WITH allowed_stores AS MATERIALIZED(SELECT r.id,r.name FROM public.restaurants r WHERE v_role='super_admin' OR r.id IN(SELECT s.store_id FROM public.user_accessible_stores(auth.uid()) s(store_id))), accessible AS (
    SELECT po.* FROM public.inventory_purchase_orders po JOIN allowed_stores scope ON scope.id=po.restaurant_id
    WHERE true
      AND (v_role <> 'inventory_accounting' OR po.status IN ('ordered','partially_received','received','office_approved'))
  ), scoped AS (
    SELECT * FROM accessible po WHERE (p_store_id IS NULL OR po.restaurant_id=p_store_id)
      AND (NOT COALESCE(p_mine_only,false) OR
        (po.status='submitted' AND v_role IN ('admin','store_admin','super_admin')) OR
        (po.status='store_approved' AND v_role IN ('brand_admin','super_admin')
          AND po.store_approved_by IS DISTINCT FROM auth.uid()))
  ), filtered AS (
    SELECT * FROM scoped WHERE p_statuses IS NULL OR status=ANY(p_statuses)
  ), page AS (
    SELECT * FROM filtered ORDER BY
      CASE WHEN status IN ('draft','submitted','store_approved','office_returned') THEN 0 ELSE 1 END,
      CASE WHEN status IN ('draft','submitted','store_approved','office_returned') THEN COALESCE(submitted_at,created_at) END ASC,
      updated_at DESC,id
    LIMIT LEAST(GREATEST(COALESCE(p_limit,80),1),240) OFFSET GREATEST(COALESCE(p_offset,0),0)
  ) SELECT jsonb_build_object(
    'orders',COALESCE((SELECT jsonb_agg((to_jsonb(po)-'approval_snapshot') || jsonb_build_object(
      'supplier',jsonb_build_object('id',s.id,'supplier_name',s.supplier_name),
      'store',jsonb_build_object('id',r.id,'name',r.name)) ORDER BY
        CASE WHEN po.status IN ('draft','submitted','store_approved','office_returned') THEN 0 ELSE 1 END,
        CASE WHEN po.status IN ('draft','submitted','store_approved','office_returned') THEN COALESCE(po.submitted_at,po.created_at) END ASC,
        po.updated_at DESC,po.id)
      FROM page po JOIN public.inventory_suppliers s ON s.id=po.supplier_id
      JOIN public.restaurants r ON r.id=po.restaurant_id),'[]'::jsonb),
    'total',(SELECT count(*) FROM filtered),
    'counts',COALESCE((SELECT jsonb_object_agg(status,n) FROM (SELECT status,count(*) n FROM scoped GROUP BY status) c),'{}'::jsonb),
    'stores',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',r.id,'name',r.name) ORDER BY r.name)
      FROM allowed_stores r),'[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;


DO $$ BEGIN
 IF has_function_privilege('authenticated','public.procurement_pre_carryover_command(uuid,text,uuid,integer,text,jsonb,jsonb)','EXECUTE') OR has_table_privilege('authenticated','public.procurement_shortage_allocations','INSERT') OR NOT has_function_privilege('authenticated','public.finalize_procurement_receipt(jsonb)','EXECUTE') THEN RAISE EXCEPTION 'PROCUREMENT_20261013_BOUNDARY_INVALID'; END IF;
END $$;
COMMIT;
