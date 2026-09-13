BEGIN;
CREATE FUNCTION public.procurement_repair_legacy_terms(p_store_id uuid,p_order_id uuid,p_expected_version integer,p_key text,p_payload jsonb,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;po public.inventory_purchase_orders%rowtype;l public.inventory_purchase_order_lines%rowtype;item jsonb;prior public.procurement_command_results%rowtype;
 h text;result jsonb;before_lines jsonb;conv numeric;tax numeric;base text;saved text:=current_setting('app.procurement_terms_repair',true);
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 IF NOT (COALESCE((actor->>'can_manage')::boolean,false) OR COALESCE((actor->>'can_senior_approve')::boolean,false)) THEN RAISE EXCEPTION 'PROCUREMENT_TERMS_REVIEW_FORBIDDEN'; END IF;
 IF NULLIF(btrim(p_key),'') IS NULL OR NULLIF(btrim(p_payload->>'reason'),'') IS NULL OR NULLIF(btrim(p_payload->>'evidence_reference'),'') IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_REASON_EVIDENCE_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text||':'||p_key,0));
 h:=encode(extensions.digest(convert_to(jsonb_build_object('action','repair_legacy_terms','order',p_order_id,'version',p_expected_version,'payload',p_payload)::text,'UTF8'),'sha256'),'hex');
 SELECT * INTO prior FROM public.procurement_command_results WHERE restaurant_id=p_store_id AND idempotency_key=p_key;
 IF FOUND THEN IF prior.actor_key IS DISTINCT FROM (actor->>'system')||':'||(actor->>'subject_id') OR prior.payload_hash<>h THEN RAISE EXCEPTION 'PROCUREMENT_RETRY_MISMATCH'; END IF;RETURN prior.result;END IF;
 SELECT * INTO po FROM public.inventory_purchase_orders WHERE id=p_order_id AND restaurant_id=p_store_id AND workflow_version=1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_LEGACY_ORDER_REQUIRED'; END IF;
 IF po.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'PROCUREMENT_STALE_VERSION'; END IF;
 IF jsonb_typeof(p_payload->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'lines')=0 THEN RAISE EXCEPTION 'PROCUREMENT_LINES_REQUIRED'; END IF;
 SELECT jsonb_agg(to_jsonb(x)) INTO before_lines FROM public.inventory_purchase_order_lines x WHERE purchase_order_id=po.id;
 PERFORM set_config('app.procurement_terms_repair','true',true);
 FOR item IN SELECT * FROM jsonb_array_elements(p_payload->'lines') LOOP
  SELECT * INTO l FROM public.inventory_purchase_order_lines WHERE id=(item->>'id')::uuid AND purchase_order_id=po.id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_LINE_INVALID'; END IF;
  conv:=(item->>'conversion')::numeric;tax:=(item->>'tax_rate')::numeric;base:=item->>'base_unit';
  IF conv IS NULL OR conv<=0 OR conv::text IN ('NaN','Infinity','-Infinity') OR tax IS NULL OR tax NOT BETWEEN 0 AND 100 OR tax::text='NaN' OR base NOT IN ('g','ml','ea') OR base IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_TERMS_INVALID'; END IF;
  IF (l.order_unit_quantity_base_snapshot IS NOT NULL AND l.order_unit_quantity_base_snapshot<>conv) OR (l.tax_rate_snapshot IS NOT NULL AND l.tax_rate_snapshot<>tax)
    OR base IS DISTINCT FROM (SELECT p.base_unit FROM public.inventory_products p WHERE p.id=l.product_id) THEN RAISE EXCEPTION 'PROCUREMENT_EXISTING_TERMS_IMMUTABLE'; END IF;
  UPDATE public.inventory_purchase_order_lines SET order_unit_quantity_base_snapshot=conv,tax_rate_snapshot=tax,base_unit_snapshot=base WHERE id=l.id;
 END LOOP;
 UPDATE public.inventory_purchase_orders SET row_version=row_version+1,updated_at=now() WHERE id=po.id RETURNING to_jsonb(inventory_purchase_orders) INTO result;
 INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,previous_state,next_state,reason)
 VALUES(p_store_id,po.id,'repair_legacy_terms',actor,before_lines,jsonb_build_object('order',result,'review',p_payload),p_payload->>'reason');
 INSERT INTO public.procurement_command_results(restaurant_id,idempotency_key,actor_key,payload_hash,result) VALUES(p_store_id,p_key,(actor->>'system')||':'||(actor->>'subject_id'),h,result);
 PERFORM set_config('app.procurement_terms_repair',COALESCE(saved,''),true);RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_repair_legacy_terms(uuid,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon,authenticated,service_role;
COMMIT;
