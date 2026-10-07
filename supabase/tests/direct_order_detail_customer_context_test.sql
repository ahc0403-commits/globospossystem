-- Disposable synthetic fixtures only. Never run against the production DB.
BEGIN;
DO $$ BEGIN IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF; END $$;
DO $$
DECLARE f jsonb; other jsonb; rid uuid; sid uuid; secret text; v3 jsonb; v4 jsonb; err text;
BEGIN
  f:=photo_test.create_request(true); rid:=(f->>'request_id')::uuid;
  SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=rid;
  SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
  UPDATE public.direct_order_requests SET customer_note=E'수령 전에 연락\n문 앞에서 기다려 주세요',diner_count=4 WHERE id=rid;
  INSERT INTO public.direct_order_request_addresses(request_id,restaurant_id,customer_name,customer_phone,
    formatted_address,detail_address,district,ward,address_source)
  SELECT rid,restaurant_id,'Synthetic customer','0900000000','Synthetic street','Door 7',
    'Synthetic district','Synthetic ward','manual' FROM public.direct_order_requests WHERE id=rid;
  UPDATE public.direct_order_request_items SET item_note=E'파 제외\n소스 별도' WHERE request_id=rid;
  v3:=public.direct_order_public_status_v3(sid,secret,rid);
  v4:=public.direct_order_public_status_v4(sid,secret,rid);
  ASSERT NOT (v3 ? 'customer'), 'V3_STRICT_CUSTOMER_CHANGED';
  ASSERT v4 - 'customer'=v3, 'EXISTING_STATUS_CHANGED';
  ASSERT v4->'customer'=jsonb_build_object('customer_name','Synthetic customer','customer_phone','0900000000',
    'formatted_address','Synthetic street','detail_address','Door 7','district','Synthetic district','ward','Synthetic ward',
    'customer_note',E'수령 전에 연락\n문 앞에서 기다려 주세요'), 'CUSTOMER_INPUTS_LOST';
  ASSERT v4->'delivery'->>'diner_count'='4', 'DINER_COUNT_LOST';
  ASSERT v4->'items'->0->>'note'=E'파 제외\n소스 별도', 'ITEM_NOTE_LOST';
  ASSERT NOT (v4->'customer' ?| ARRAY['session_id','secret_hash','google_place_id','created_by','attachment_storage_path']), 'EXTRA_CUSTOMER_PII';
  BEGIN PERFORM public.direct_order_public_status_v4(sid,repeat('f',64),rid); EXCEPTION WHEN OTHERS THEN err:=SQLERRM; END;
  ASSERT err='DIRECT_ORDER_SESSION_INVALID', 'WRONG_SECRET_READ_PII';
  other:=photo_test.create_request(true); err:=NULL;
  BEGIN PERFORM public.direct_order_public_status_v4(sid,secret,(other->>'request_id')::uuid); EXCEPTION WHEN OTHERS THEN err:=SQLERRM; END;
  ASSERT err='DIRECT_ORDER_REQUEST_NOT_FOUND', 'OTHER_SESSION_READ_PII';
  -- A converted pickup keeps all information the customer originally entered.
  UPDATE public.direct_order_requests SET fulfillment_method='pickup' WHERE id=rid;
  v4:=public.direct_order_public_status_v4(sid,secret,rid);
  ASSERT v4->'customer'->>'customer_name'='Synthetic customer', 'PICKUP_CONTACT_LOST';
  ASSERT v4->'customer'->>'formatted_address'='Synthetic street', 'PICKUP_ORIGINAL_INPUT_LOST';
  UPDATE public.direct_order_requests SET pii_purged_at=now(),customer_note=NULL WHERE id=rid;
  DELETE FROM public.direct_order_request_addresses WHERE request_id=rid;
  ASSERT public.direct_order_public_status_v4(sid,secret,rid)->'customer'='null'::jsonb, 'PURGED_PII_RESURRECTED';
  ASSERT NOT has_function_privilege('anon','public.direct_order_public_status_v4(uuid,text,uuid)','EXECUTE'), 'ANON_PII_RPC_ACCESS';
  ASSERT NOT has_function_privilege('authenticated','public.direct_order_public_status_v4(uuid,text,uuid)','EXECUTE'), 'STAFF_BYPASS_OWNERSHIP';
  ASSERT has_function_privilege('service_role','public.direct_order_public_status_v4(uuid,text,uuid)','EXECUTE'), 'EDGE_RPC_DENIED';
END $$;
ROLLBACK;
SELECT 'DIRECT_ORDER_DETAIL_CUSTOMER_CONTEXT_SQL=PASS';
