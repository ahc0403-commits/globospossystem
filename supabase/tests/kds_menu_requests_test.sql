DO $notes$
DECLARE o uuid;i uuid;q uuid:=gen_random_uuid();other_q uuid:=gen_random_uuid();j jsonb;result jsonb;n integer;
BEGIN
 SELECT order_id,id INTO o,i FROM public.order_items WHERE item_type='menu_item' LIMIT 1;
 UPDATE public.order_items SET notes='không hành lá' WHERE id=i;
 INSERT INTO public.emergency_order_queue(id,order_id) VALUES(q,o),(other_q,gen_random_uuid());
 j:=jsonb_build_array(jsonb_build_object('queue_id',q,'items',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'order_item_id',i,'ordered_quantity',1))));
 result:=public.emergency_enrich_start_ready_orders(j);
 IF result->0->'items'->0->>'notes'<>'không hành lá' THEN RAISE EXCEPTION 'KDS_ITEM_REQUEST_MISSING';END IF;
 j:=jsonb_set(j,'{0,queue_id}',to_jsonb(other_q));result:=public.emergency_enrich_start_ready_orders(j);
 IF result->0->'items'->0->>'notes' IS NOT NULL THEN RAISE EXCEPTION 'KDS_OTHER_ORDER_NOTE_LEAK';END IF;
 FOR n IN SELECT unnest(ARRAY[1,100,500]) LOOP
  SELECT jsonb_agg(jsonb_build_object('id',gen_random_uuid(),'order_item_id',i,'ordered_quantity',1)) INTO result FROM generate_series(1,n);
  j:=jsonb_build_array(jsonb_build_object('queue_id',q,'items',result));result:=public.emergency_enrich_start_ready_orders(j);
  IF jsonb_array_length(result->0->'items')<>n OR EXISTS(SELECT 1 FROM jsonb_array_elements(result->0->'items') x WHERE x->>'notes'<>'không hành lá') THEN RAISE EXCEPTION 'KDS_MENU_REQUEST_BATCH_LOST';END IF;
  RAISE NOTICE 'KDS_MENU_REQUEST_BATCH=PASS items=%',n;
 END LOOP;
 IF public.emergency_enrich_start_ready_orders('{}')<>'[]' THEN RAISE EXCEPTION 'KDS_MENU_INVALID_INPUT';END IF;
END;
$notes$;
