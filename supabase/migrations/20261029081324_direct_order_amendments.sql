-- Same-request amendments. Parent-row locks serialize edits, quotes and proofs.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
CREATE TABLE public.direct_order_amendments (
 request_id uuid NOT NULL REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
 operation_id uuid NOT NULL, restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 input jsonb NOT NULL, before_items jsonb NOT NULL, after_items jsonb NOT NULL,
 result jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(request_id,operation_id)
);
ALTER TABLE public.direct_order_amendments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_amendments FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.direct_order_amendments TO service_role;
CREATE INDEX direct_order_amendments_history ON public.direct_order_amendments(request_id,created_at DESC);

CREATE FUNCTION public.direct_order_edit_token(p_request_id uuid) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT md5(jsonb_build_object('state',r.state,'items',
 (SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.sort_order,i.id),'[]') FROM public.direct_order_request_items i WHERE i.request_id=r.id),
 'quote',(SELECT q.id FROM public.direct_order_quotes q WHERE q.request_id=r.id AND q.status IN('active','locked') LIMIT 1))::text)
 FROM public.direct_order_requests r WHERE r.id=$1;
$$;
REVOKE ALL ON FUNCTION public.direct_order_edit_token(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.direct_order_public_amendment_context(p_session_id uuid,p_secret_hash text,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE s public.direct_order_sessions%ROWTYPE; r public.direct_order_requests%ROWTYPE;
BEGIN
 s:=public.direct_order_validate_session($1,$2);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$3 AND session_id=s.id AND restaurant_id=s.restaurant_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF r.state NOT IN('awaiting_quote','quoted') OR EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=r.id)
 OR EXISTS(SELECT 1 FROM public.direct_order_payment_receipts WHERE request_id=r.id)
 OR EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r.id)
 THEN RAISE EXCEPTION 'DIRECT_ORDER_AMENDMENT_NOT_ALLOWED'; END IF;
 RETURN jsonb_build_object('request_id',r.id,'token',public.direct_order_edit_token(r.id),'items',
 (SELECT coalesce(jsonb_agg(jsonb_build_object('id',i.id,'menu_item_id',i.menu_item_id,'name_ko',i.name_ko,'name_vi',i.name_vi,'name_en',i.name_en,
 'quantity',i.quantity,'unit_price',i.unit_price,'is_combo',jsonb_array_length(i.combo_components)>0) ORDER BY i.sort_order,i.id),'[]')
 FROM public.direct_order_request_items i WHERE i.request_id=r.id));
END $$;
REVOKE ALL ON FUNCTION public.direct_order_public_amendment_context(uuid,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_amendment_context(uuid,text,uuid) TO service_role;

-- Reuse the effective menu/option/VAT validator in one batch. Saved amendments
-- can contain distinct lines for the same menu choice, so line ordinals (rather
-- than menu IDs) retain identity. The public submit contract is unchanged.
DO $batch$
DECLARE d text; needle text := $n$OR (SELECT count(DISTINCT ROW((e->>'menu_item_id')::uuid,e->>'menu_option_key')) FROM jsonb_array_elements(p_items)e)<>jsonb_array_length(p_items)$n$;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_prepare_combo_items(uuid,jsonb)'::regprocedure) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_AMENDMENT_BATCH_DRIFT'; END IF;
 d:=replace(d,'FUNCTION public.direct_order_prepare_combo_items(', 'FUNCTION public.direct_order_prepare_amendment_combos(');
 d:=replace(d,needle,'');
 d:=replace(d,'NOT BETWEEN 1 AND 50','NOT BETWEEN 1 AND 100');
 EXECUTE d;
END $batch$;
REVOKE ALL ON FUNCTION public.direct_order_prepare_amendment_combos(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.direct_order_public_amend(p_session_id uuid,p_secret_hash text,p_request_id uuid,p_operation_id uuid,p_token text,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE s public.direct_order_sessions%ROWTYPE; r public.direct_order_requests%ROWTYPE;
 replay public.direct_order_amendments%ROWTYPE; before_lines jsonb; after_lines jsonb; prepared jsonb;
 old_line public.direct_order_request_items%ROWTYPE; change jsonb; qty integer; rebuilt jsonb;
 previous_prepared text; combo_inputs jsonb; combo_prepared jsonb; result jsonb; amounts jsonb; offset_n integer;
BEGIN
 s:=public.direct_order_validate_session($1,$2);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$3 AND session_id=s.id AND restaurant_id=s.restaurant_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF p_operation_id IS NULL OR p_token IS NULL OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
 OR jsonb_typeof(p_payload->'existing') IS DISTINCT FROM 'array' OR jsonb_typeof(p_payload->'additions') IS DISTINCT FROM 'array'
 OR jsonb_array_length(p_payload->'existing')>100 OR jsonb_array_length(p_payload->'additions')>50 OR octet_length(p_payload::text)>131072
 THEN RAISE EXCEPTION 'DIRECT_ORDER_AMENDMENT_INPUT_INVALID'; END IF;
 SELECT * INTO replay FROM public.direct_order_amendments WHERE request_id=r.id AND operation_id=$4;
 IF FOUND THEN
  IF replay.input IS DISTINCT FROM jsonb_build_object('token',p_token,'payload',p_payload) THEN RAISE EXCEPTION 'DIRECT_ORDER_AMENDMENT_RETRY_CHANGED'; END IF;
  RETURN replay.result;
 END IF;
 PERFORM public.direct_order_public_amendment_context($1,$2,$3);
 IF public.direct_order_edit_token(r.id) IS DISTINCT FROM p_token THEN RAISE EXCEPTION 'DIRECT_ORDER_AMENDMENT_STALE'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'existing') e WHERE coalesce(e->>'quantity','') !~ '^(0|[1-9][0-9]?)$' OR (e->>'quantity')::integer>50)
 OR (SELECT count(*) FROM jsonb_array_elements(p_payload->'existing'))<>(SELECT count(DISTINCT e->>'id') FROM jsonb_array_elements(p_payload->'existing') e)
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_payload->'existing') e WHERE NOT EXISTS(SELECT 1 FROM public.direct_order_request_items i WHERE i.request_id=r.id AND i.id::text=e->>'id'))
 OR jsonb_array_length(p_payload->'existing')<>(SELECT count(*) FROM public.direct_order_request_items WHERE request_id=r.id)
 THEN RAISE EXCEPTION 'DIRECT_ORDER_AMENDMENT_INPUT_INVALID'; END IF;
 -- Validate the final count before preparing any component snapshots.
 IF (SELECT coalesce(sum((e->>'quantity')::integer),0) FROM jsonb_array_elements(p_payload->'existing')e)>100
 THEN RAISE EXCEPTION 'DIRECT_ORDER_QUANTITY_LIMIT'; END IF;
 SELECT jsonb_agg(jsonb_build_object('saved_line_id',i.id,'menu_item_id',i.menu_item_id,'quantity',(e->>'quantity')::integer,'note',i.item_note,
  'menu_option_key',i.menu_option_snapshot->>'selection_key','combo_drink_choices',
  (SELECT coalesce(jsonb_agg(i.combo_drink_choices->(g % greatest(1,jsonb_array_length(i.combo_drink_choices))) ORDER BY g),'[]')
   FROM generate_series(0,(e->>'quantity')::integer*jsonb_array_length(i.combo_drink_choices)/i.quantity-1)g)) ORDER BY i.id)
 INTO combo_inputs FROM public.direct_order_request_items i JOIN jsonb_array_elements(p_payload->'existing')e ON e->>'id'=i.id::text
 WHERE i.request_id=r.id AND jsonb_array_length(i.combo_components)>0 AND (e->>'quantity')::integer>0 AND (e->>'quantity')::integer<>i.quantity;
 IF combo_inputs IS NOT NULL THEN
  combo_prepared:=public.direct_order_prepare_amendment_combos(r.restaurant_id,combo_inputs);
 END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY sort_order,id),'[]') INTO before_lines FROM public.direct_order_request_items i WHERE request_id=r.id;
 -- Only lifecycle status changes; finalized quote amounts and IDs remain immutable.
 UPDATE public.direct_order_messages SET metadata=metadata||jsonb_build_object('voided_by_amendment',true) WHERE request_id=r.id AND metadata->>'quote_id' IN(SELECT id::text FROM public.direct_order_quotes WHERE request_id=r.id AND status='active');
 UPDATE public.direct_order_quotes SET status='expired' WHERE request_id=r.id AND status='active';
 previous_prepared:=current_setting('pos.direct_prepared_items',true);
 FOR old_line IN SELECT * FROM public.direct_order_request_items WHERE request_id=r.id ORDER BY id LOOP
  SELECT e INTO change FROM jsonb_array_elements(p_payload->'existing') e WHERE e->>'id'=old_line.id::text;
  qty:=(change->>'quantity')::integer;
  IF qty=old_line.quantity THEN CONTINUE; END IF;
  IF qty=0 THEN
   DELETE FROM public.direct_order_customer_requirements WHERE request_id=r.id AND source_kind='item' AND source_id=old_line.id;
   DELETE FROM public.direct_order_request_items WHERE id=old_line.id;
  ELSIF jsonb_array_length(old_line.combo_components)=0 THEN
   UPDATE public.direct_order_request_items SET quantity=qty WHERE id=old_line.id;
  ELSE
   -- Resize the saved explicit drink selection deterministically. All component
   -- prices, VAT rates and selected menu choices must still match the snapshot.
   SELECT prepared_line INTO rebuilt FROM jsonb_array_elements(combo_prepared) prepared_line
   WHERE combo_inputs->((prepared_line->>'sort_order')::integer)->>'saved_line_id'=old_line.id::text;
   IF (rebuilt->>'unit_price')::numeric<>old_line.unit_price OR rebuilt->'menu_option_snapshot' IS DISTINCT FROM old_line.menu_option_snapshot
   OR EXISTS(SELECT 1 FROM jsonb_array_elements(rebuilt->'combo_components') n WHERE NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements(old_line.combo_components) o WHERE o->>'menu_item_id'=n->>'menu_item_id'
     AND o->'tax_unit_price'=n->'tax_unit_price' AND o->'tax_vat_rate'=n->'tax_vat_rate' AND o->'fixed_quantity'=n->'fixed_quantity'))
   OR EXISTS(SELECT 1 FROM jsonb_array_elements(old_line.combo_components) o WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(rebuilt->'combo_components') n WHERE o->>'menu_item_id'=n->>'menu_item_id'))
   THEN RAISE EXCEPTION 'DIRECT_ORDER_MENU_CHANGED'; END IF;
   rebuilt:=jsonb_set(rebuilt,'{combo_components}',(SELECT jsonb_agg(o||jsonb_build_object('quantity',n->'quantity') ORDER BY ord) FROM jsonb_array_elements(old_line.combo_components) WITH ORDINALITY saved(o,ord) JOIN jsonb_array_elements(rebuilt->'combo_components') n ON n->>'menu_item_id'=o->>'menu_item_id'));
   rebuilt:=rebuilt||jsonb_build_object('line_id',old_line.id,'sort_order',old_line.sort_order);
   DELETE FROM public.direct_order_request_items WHERE id=old_line.id;
   PERFORM set_config('pos.direct_prepared_items',jsonb_build_object(old_line.id::text,rebuilt)::text,true);
   INSERT INTO public.direct_order_request_items SELECT (jsonb_populate_record(NULL::public.direct_order_request_items,
    to_jsonb(old_line)||jsonb_build_object('quantity',qty,'combo_components',rebuilt->'combo_components','combo_drink_choices',rebuilt->'combo_drink_choices','vat_profile_snapshot',rebuilt->'vat_profile_snapshot'))).*;
  END IF;
 END LOOP;
 IF jsonb_array_length(p_payload->'additions')>0 THEN
  prepared:=public.direct_order_prepare_combo_items(r.restaurant_id,p_payload->'additions');
  PERFORM set_config('pos.direct_prepared_items',(SELECT jsonb_object_agg(e->>'line_id',e) FROM jsonb_array_elements(prepared)e)::text,true);
  SELECT coalesce(max(sort_order)+1,0) INTO offset_n FROM public.direct_order_request_items WHERE request_id=r.id;
  INSERT INTO public.direct_order_request_items(id,request_id,restaurant_id,menu_item_id,display_name,name_ko,name_vi,name_en,vat_category,unit_price,quantity,item_note,sort_order,combo_drink_choices,combo_components,vat_profile_snapshot,menu_option_snapshot)
  SELECT (e->>'line_id')::uuid,r.id,r.restaurant_id,(e->>'menu_item_id')::uuid,e->>'display_name',e->>'name_ko',e->>'name_vi',e->>'name_en',e->>'vat_category',
  (e->>'unit_price')::numeric,(e->>'quantity')::integer,e->>'item_note',offset_n+(e->>'sort_order')::integer,e->'combo_drink_choices',e->'combo_components',e->'vat_profile_snapshot',coalesce(e->'menu_option_snapshot','{}') FROM jsonb_array_elements(prepared)e;
 END IF;
 PERFORM set_config('pos.direct_prepared_items',coalesce(previous_prepared,''),true);
 IF (SELECT coalesce(sum(quantity),0)>100 OR count(*)>100 FROM public.direct_order_request_items WHERE request_id=r.id) THEN RAISE EXCEPTION 'DIRECT_ORDER_QUANTITY_LIMIT'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY sort_order,id),'[]') INTO after_lines FROM public.direct_order_request_items i WHERE request_id=r.id;
 IF after_lines='[]'::jsonb THEN
  UPDATE public.direct_order_requests SET state='cancelled',cancelled_at=now(),updated_at=clock_timestamp() WHERE id=r.id;
 ELSE
  amounts:=public.direct_order_quote_preview_core(r.restaurant_id,r.id,false);
  UPDATE public.direct_order_requests SET state='awaiting_quote',updated_at=clock_timestamp() WHERE id=r.id;
 END IF;
 result:=jsonb_build_object('request_id',r.id,'state',CASE WHEN after_lines='[]'::jsonb THEN 'cancelled' ELSE 'awaiting_quote' END,'amounts',amounts);
 INSERT INTO public.direct_order_amendments(request_id,operation_id,restaurant_id,input,before_items,after_items,result)
 VALUES(r.id,$4,r.restaurant_id,jsonb_build_object('token',p_token,'payload',p_payload),before_lines,after_lines,result);
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,metadata)
 VALUES(r.id,r.restaurant_id,'system','system','DIRECT_ORDER_AMENDED',jsonb_build_object('amended',true,'operation_id',$4));
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.direct_order_public_amend(uuid,text,uuid,uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_amend(uuid,text,uuid,uuid,text,jsonb) TO service_role;

CREATE FUNCTION public.direct_order_staff_detail_v9(p_store_id uuid,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE b jsonb;
BEGIN
 b:=public.direct_order_staff_detail_v8($1,$2);
 RETURN b||jsonb_build_object('edit_token',public.direct_order_edit_token($2),'amendments',
 (SELECT coalesce(jsonb_agg(jsonb_build_object('created_at',a.created_at,'before_items',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',e->'id','name_ko',e->'name_ko','name_vi',e->'name_vi','name_en',e->'name_en','quantity',e->'quantity')),'[]') FROM jsonb_array_elements(a.before_items)e),'after_items',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',e->'id','name_ko',e->'name_ko','name_vi',e->'name_vi','name_en',e->'name_en','quantity',e->'quantity')),'[]') FROM jsonb_array_elements(a.after_items)e)) ORDER BY a.created_at DESC),'[]')
 FROM (SELECT * FROM public.direct_order_amendments WHERE request_id=$2 AND restaurant_id=$1 ORDER BY created_at DESC LIMIT 20)a));
END $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_detail_v9(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_detail_v9(uuid,uuid) TO authenticated,service_role;
CREATE FUNCTION public.direct_order_staff_quote_current(p_store_id uuid,p_request_id uuid,p_delivery_fee_total numeric,p_cashier_note text,p_delivery_payment_mode text,p_expected_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 PERFORM 1 FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF p_expected_token IS NULL OR public.direct_order_edit_token($2) IS DISTINCT FROM p_expected_token THEN RAISE EXCEPTION 'DIRECT_ORDER_AMENDMENT_STALE'; END IF;
 RETURN public.direct_order_staff_quote_with_payment_mode($1,$2,$3,$4,$5);
END $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_quote_current(uuid,uuid,numeric,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_quote_current(uuid,uuid,numeric,text,text,text) TO authenticated,service_role;
CREATE FUNCTION public.direct_order_staff_list_v6(p_store_id uuid,p_states text[] DEFAULT NULL,p_limit integer DEFAULT 100,p_fulfillment_type text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH page AS MATERIALIZED(SELECT e.value,e.ordinality FROM jsonb_array_elements(public.direct_order_staff_list_v5($1,$2,$3,$4)) WITH ORDINALITY e),
 edits AS(SELECT a.request_id,max(a.created_at) amended_at FROM public.direct_order_amendments a JOIN page p ON a.request_id=(p.value->>'id')::uuid GROUP BY a.request_id)
 SELECT coalesce(jsonb_agg(p.value||jsonb_build_object('amended_at',e.amended_at) ORDER BY p.ordinality),'[]') FROM page p LEFT JOIN edits e ON e.request_id=(p.value->>'id')::uuid;
$$;
REVOKE ALL ON FUNCTION public.direct_order_staff_list_v6(uuid,text[],integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_list_v6(uuid,text[],integer,text) TO authenticated,service_role;
DO $$ BEGIN
 IF has_function_privilege('anon','public.direct_order_public_amend(uuid,text,uuid,uuid,text,jsonb)','EXECUTE')
 OR has_table_privilege('authenticated','public.direct_order_amendments','SELECT') THEN RAISE EXCEPTION 'AMENDMENT_PERMISSIONS_INVALID'; END IF;
END $$;
COMMIT;
