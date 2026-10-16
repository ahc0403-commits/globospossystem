-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';

-- Preserve existing authorization, locks, evidence checks and payment posting.
ALTER FUNCTION public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text)
 RENAME TO direct_order_record_receipt_before_balance_guidance;
REVOKE ALL ON FUNCTION public.direct_order_record_receipt_before_balance_guidance(uuid,uuid,uuid,uuid,numeric,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_record_receipt(p_store_id uuid,p_request_id uuid,p_quote_id uuid,p_proof_message_id uuid,p_amount numeric,p_bank_reference text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;due numeric;
BEGIN
 result:=public.direct_order_record_receipt_before_balance_guidance($1,$2,$3,$4,$5,$6);
 due:=(result->>'food_due')::numeric;
 IF due>0 AND due=trunc(due) AND EXISTS(
   SELECT 1 FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1
   AND state IN ('quoted','awaiting_payment_review') AND support_closed_at IS NULL)
 AND NOT EXISTS(
   SELECT 1 FROM public.direct_order_payment_charges WHERE request_id=$2 AND kind='food_balance' AND status IN ('pending','review')) THEN
  INSERT INTO public.direct_order_payment_charges(request_id,restaurant_id,kind,amount,reason,status,created_by)
  VALUES($2,$1,'food_balance',due,'Outstanding food payment','pending',auth.uid());
  UPDATE public.direct_order_requests SET support_version=support_version+1 WHERE id=$2;
  result:=public.direct_order_support_context($2,true);
 END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text) TO authenticated,service_role;

-- A bounded capability response separates receivers from PR accounts sharing
-- inventory_orderer. It does not grant any new write capability.
ALTER FUNCTION public.get_inventory_order_catalog(uuid) RENAME TO get_inventory_order_catalog_before_receiving_guidance;
REVOKE ALL ON FUNCTION public.get_inventory_order_catalog_before_receiving_guidance(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.get_inventory_order_catalog(p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;actor jsonb;receiver boolean;
BEGIN
 result:=public.get_inventory_order_catalog_before_receiving_guidance(p_store_id);
 actor:=public.procurement_actor(p_store_id);
 receiver:=actor->>'role'='inventory_orderer' AND COALESCE((actor->>'can_receive')::boolean,false)
  AND NOT EXISTS(SELECT 1 FROM public.procurement_role_roster WHERE restaurant_id=p_store_id AND system='pos'
    AND subject_id=auth.uid() AND stage='requester' AND valid_from<=now() AND valid_until>now());
 RETURN result||jsonb_build_object('actor',actor||jsonb_build_object('receiving_only',receiver));
END $$;
REVOKE ALL ON FUNCTION public.get_inventory_order_catalog(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_order_catalog(uuid) TO authenticated;

-- Enrich only the selected PO's already authorized lines, in one join.
ALTER FUNCTION public.get_inventory_workflow_detail(uuid) RENAME TO get_inventory_workflow_detail_before_receiving_guidance;
REVOKE ALL ON FUNCTION public.get_inventory_workflow_detail_before_receiving_guidance(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.get_inventory_workflow_detail(p_purchase_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;lines jsonb;store uuid;
BEGIN
 result:=public.get_inventory_workflow_detail_before_receiving_guidance($1);
 store:=(result->'order'->>'restaurant_id')::uuid;
 SELECT COALESCE(jsonb_agg(e.line||jsonb_build_object(
  'current_stock_base',i.current_stock,'stock_base_unit',p.base_unit,
  'product',COALESCE(e.line->'product','{}'::jsonb)||jsonb_strip_nulls(jsonb_build_object(
    'name_ko',to_jsonb(p)->>'name_ko','name_vi',to_jsonb(p)->>'name_vi','name_en',to_jsonb(p)->>'name_en')))
  ORDER BY e.n),'[]'::jsonb) INTO lines
 FROM jsonb_array_elements(COALESCE(result->'lines','[]'::jsonb)) WITH ORDINALITY e(line,n)
 LEFT JOIN public.inventory_products p ON p.id=(e.line->>'product_id')::uuid AND p.restaurant_id=store
 LEFT JOIN public.inventory_items i ON i.id=p.inventory_item_id AND i.restaurant_id=store;
 RETURN jsonb_set(result,'{lines}',lines);
END $$;
REVOKE ALL ON FUNCTION public.get_inventory_workflow_detail(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_workflow_detail(uuid) TO authenticated;

DO $$ BEGIN
 IF has_function_privilege('anon','public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text)','EXECUTE')
 OR has_function_privilege('anon','public.get_inventory_order_catalog(uuid)','EXECUTE')
 OR has_function_privilege('anon','public.get_inventory_workflow_detail(uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_record_receipt_before_balance_guidance(uuid,uuid,uuid,uuid,numeric,text)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.get_inventory_workflow_detail(uuid)','EXECUTE')
 THEN RAISE EXCEPTION 'POS_RECEIVING_BALANCE_GUIDANCE_PRIVILEGE_INVALID'; END IF;
END $$;
COMMIT;
