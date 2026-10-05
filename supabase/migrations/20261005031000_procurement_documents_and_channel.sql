BEGIN;
CREATE OR REPLACE FUNCTION public.procurement_allowed_actions(p_request public.inventory_purchase_requests,p_actor jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
 SELECT to_jsonb(array_remove(ARRAY[
 CASE WHEN p_request.status IN ('draft','returned') AND p_request.created_actor->>'system'=p_actor->>'system'
   AND p_request.created_actor->>'subject_id'=p_actor->>'subject_id' AND (p_actor->>'can_create')::boolean THEN 'save_request' END,
 CASE WHEN p_request.status IN ('draft','returned') AND p_request.created_actor->>'system'=p_actor->>'system'
   AND p_request.created_actor->>'subject_id'=p_actor->>'subject_id' AND (p_actor->>'can_create')::boolean THEN 'submit_request' END,
 CASE WHEN p_request.status='submitted' AND (p_actor->>'can_store_approve')::boolean THEN 'adjust_request' END,
 CASE WHEN p_request.status='submitted' AND (p_actor->>'can_store_approve')::boolean THEN 'store_approve' END,
 CASE WHEN p_request.status='brand_review' AND (p_actor->>'can_brand_approve')::boolean
   AND (p_request.store_approved_actor->>'system'<>p_actor->>'system' OR p_request.store_approved_actor->>'subject_id'<>p_actor->>'subject_id') THEN 'brand_approve' END,
 CASE WHEN p_request.status='submitted' AND (p_actor->>'can_store_approve')::boolean
   OR p_request.status='brand_review' AND (p_actor->>'can_brand_approve')::boolean
   OR p_request.status IN ('office_review','senior_review') AND (p_actor->>'can_office_approve')::boolean THEN 'return_request' END,
 CASE WHEN p_request.status NOT IN ('allocated','cancelled') AND ((p_actor->>'can_office_approve')::boolean OR
   p_request.status IN ('draft','returned') AND p_request.created_actor->>'subject_id'=p_actor->>'subject_id'
   AND p_request.created_actor->>'system'=p_actor->>'system') THEN 'cancel_request' END,
 CASE WHEN p_request.status IN ('brand_review','office_review','senior_review','approved') AND (p_actor->>'can_office_approve')::boolean THEN 'save_quote' END,
 CASE WHEN p_request.status IN ('brand_review','office_review','senior_review','approved') AND (p_actor->>'can_office_approve')::boolean THEN 'select_quote' END,
 CASE WHEN p_request.status='office_review' AND (p_actor->>'can_office_approve')::boolean AND (p_request.approval_policy_version=1 OR
   p_request.brand_approved_actor->>'system'<>p_actor->>'system' OR p_request.brand_approved_actor->>'subject_id'<>p_actor->>'subject_id') THEN 'office_approve' END,
 CASE WHEN p_request.status='senior_review' AND (p_actor->>'can_senior_approve')::boolean
   AND (p_request.office_approved_actor->>'system'<>p_actor->>'system' OR p_request.office_approved_actor->>'subject_id'<>p_actor->>'subject_id') THEN 'senior_approve' END,
 CASE WHEN p_request.status='approved' AND (p_actor->>'can_office_approve')::boolean THEN 'issue_po' END
 ]::text[],NULL))
$$;

-- An allowlist projection is the only source for a supplier-facing document.
-- It never contains the internal approval snapshot or supplier banking fields.
CREATE FUNCTION public.procurement_document_data(p_store_id uuid,p_kind text,p_record_id uuid,p_audience text,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb; po public.inventory_purchase_orders%rowtype; req public.inventory_purchase_requests%rowtype; result jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 IF p_kind NOT IN ('pr','po') OR p_audience NOT IN ('internal','supplier') OR (p_kind='pr' AND p_audience<>'internal') THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_AUDIENCE_INVALID'; END IF;
 IF p_kind='po' THEN
   SELECT * INTO po FROM public.inventory_purchase_orders WHERE id=p_record_id AND restaurant_id=p_store_id AND workflow_version=2;
   IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
   IF p_audience='internal' AND NOT COALESCE((actor->>'can_view_prices')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_PRICES_FORBIDDEN'; END IF;
   IF p_audience='supplier' THEN
     result:=jsonb_build_object('purchase_order_no',po.purchase_order_no,'commercial_revision',po.commercial_revision,
       'issued_at',po.commercial_terms->'issued_at','requested_delivery_date',po.requested_delivery_date,
       'pr_no',po.commercial_terms->'pr_no','pr_created_at',po.commercial_terms->'pr_created_at','pr_submitted_at',po.commercial_terms->'pr_submitted_at',
       'supplier_name',po.approval_snapshot->'supplier'->'supplier_name','store_name',po.approval_snapshot->'store'->'name',
       'delivery_address',po.commercial_terms->'delivery_address','contact_name',po.commercial_terms->'contact_name',
       'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object('product_name',l->'product_name','specification',l->'specification',
         'quantity',l->'ordered_quantity_unit','unit',l->'order_unit','memo',l->'memo') ORDER BY l->>'id')
         FROM jsonb_array_elements(po.approval_snapshot->'lines') l),'[]'));
   ELSE result:=to_jsonb(po); END IF;
   RETURN jsonb_build_object('kind','po','audience',p_audience,'source_hash',po.approval_snapshot_hash,'data',result);
 ELSE
   SELECT * INTO req FROM public.inventory_purchase_requests WHERE id=p_record_id AND restaurant_id=p_store_id;
   IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
   result:=to_jsonb(req)-'approval_hash'-'brand_approval_hash';
   IF NOT COALESCE((actor->>'can_view_prices')::boolean,false) THEN result:=result-'approved_amount'; END IF;
   result:=result||jsonb_build_object('store_name',(SELECT name FROM public.restaurants WHERE id=p_store_id),
     'lines',COALESCE((SELECT jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',COALESCE(l.product_name_snapshot,p.name)) ORDER BY l.id)
     FROM public.inventory_purchase_request_lines l JOIN public.inventory_products p ON p.id=l.product_id WHERE l.request_id=req.id AND l.active),'[]'));
   result:=result||(SELECT jsonb_build_object('estimates_complete',COALESCE(bool_and(l.estimated_unit_price IS NOT NULL AND l.estimated_conversion>0),false),
     'estimated_net',sum(round(l.quantity_base/NULLIF(l.estimated_conversion,0)*l.estimated_unit_price,2)),
     'estimated_vat',sum(round(l.quantity_base/NULLIF(l.estimated_conversion,0)*l.estimated_unit_price*l.estimated_tax_rate/100,2)),
     'estimated_total',sum(round(l.quantity_base/NULLIF(l.estimated_conversion,0)*l.estimated_unit_price,2)+round(l.quantity_base/NULLIF(l.estimated_conversion,0)*l.estimated_unit_price*l.estimated_tax_rate/100,2)))
     FROM public.inventory_purchase_request_lines l WHERE l.request_id=req.id AND l.active);
   RETURN jsonb_build_object('kind','pr','audience','internal','source_hash',encode(extensions.digest(convert_to(result::text,'UTF8'),'sha256'),'hex'),'data',result);
 END IF;
END $$;
REVOKE ALL ON FUNCTION public.procurement_document_data(uuid,text,uuid,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_document_data(uuid,text,uuid,text,jsonb) TO authenticated,service_role;

CREATE FUNCTION public.record_procurement_document(p_store_id uuid,p_kind text,p_record_id uuid,p_audience text,p_source_hash text,p_storage_path text,p_sha256 text,p_size_bytes integer,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb; source jsonb; result jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 IF NOT (COALESCE((actor->>'can_create')::boolean,false) OR COALESCE((actor->>'can_office_approve')::boolean,false)) THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_FORBIDDEN'; END IF;
 -- Lock the source so a concurrent commercial change cannot mark an obsolete export ready.
 IF p_kind='po' THEN PERFORM 1 FROM public.inventory_purchase_orders WHERE id=p_record_id AND restaurant_id=p_store_id FOR UPDATE;
 ELSE PERFORM 1 FROM public.inventory_purchase_requests WHERE id=p_record_id AND restaurant_id=p_store_id FOR UPDATE; END IF;
 source:=public.procurement_document_data(p_store_id,p_kind,p_record_id,p_audience,p_office_actor);
 IF source->>'source_hash' IS DISTINCT FROM p_source_hash THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_SOURCE_CHANGED'; END IF;
 IF p_storage_path IS DISTINCT FROM p_store_id||'/procurement/'||p_kind||'/'||p_record_id||'/'||p_audience||'/'||p_source_hash||'/'||p_sha256||'.pdf' THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_PATH_INVALID'; END IF;
 IF p_size_bytes NOT BETWEEN 1 AND 5242880 OR NOT EXISTS(SELECT 1 FROM storage.objects WHERE bucket_id='inventory-purchase-documents' AND name=p_storage_path AND COALESCE((metadata->>'size')::integer,0)=p_size_bytes) THEN RAISE EXCEPTION 'PROCUREMENT_DOCUMENT_FILE_REQUIRED'; END IF;
 UPDATE public.procurement_document_exports SET status='superseded' WHERE record_id=p_record_id AND kind=p_kind AND audience=p_audience AND source_hash<>p_source_hash;
 INSERT INTO public.procurement_document_exports(restaurant_id,record_id,kind,audience,source_hash,storage_path,sha256,size_bytes,generated_actor)
 VALUES(p_store_id,p_record_id,p_kind,p_audience,p_source_hash,p_storage_path,p_sha256,p_size_bytes,actor)
 ON CONFLICT(record_id,kind,audience,source_hash,sha256) DO UPDATE SET status='ready'
 RETURNING to_jsonb(procurement_document_exports) INTO result;
 INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,next_state) VALUES(p_store_id,p_record_id,'document_generated',actor,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.record_procurement_document(uuid,text,uuid,text,text,text,text,integer,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.record_procurement_document(uuid,text,uuid,text,text,text,text,integer,jsonb) TO authenticated,service_role;
COMMIT;
