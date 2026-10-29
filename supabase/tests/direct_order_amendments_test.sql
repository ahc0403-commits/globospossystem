BEGIN;
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
DO $$
DECLARE shop uuid:='d1000000-0000-4000-8000-000000000002'; r uuid; sid uuid; secret text; ctx jsonb; q jsonb; v jsonb; payload jsonb; op uuid:=gen_random_uuid(); item_id uuid; menu_id uuid; ref text;
BEGIN
 UPDATE direct_order_storefronts SET is_paused=false,minimum_order_amount=0 WHERE restaurant_id=shop;
 r:=guide_test.request();
 SELECT session_id,reference_code INTO sid,ref FROM direct_order_requests WHERE id=r;
 SELECT secret_hash INTO secret FROM direct_order_sessions WHERE id=sid;
 SELECT id,menu_item_id INTO item_id,menu_id FROM direct_order_request_items WHERE request_id=r;
 q:=public.direct_order_staff_quote_with_payment_mode(shop,r,0,NULL,'customer_direct');
 ctx:=public.direct_order_public_amendment_context(sid,secret,r);
 payload:=jsonb_build_object('existing',jsonb_build_array(jsonb_build_object('id',item_id,'quantity',2)), 'additions','[]'::jsonb);
 v:=public.direct_order_public_amend(sid,secret,r,op,ctx->>'token',payload);
 IF (v->'amounts'->>'final_total')::numeric<>216000 OR v->>'state'<>'awaiting_quote' THEN RAISE EXCEPTION 'AMEND_PRICE_WRONG: %',v; END IF;
 IF (SELECT reference_code FROM direct_order_requests WHERE id=r)<>ref OR (SELECT status FROM direct_order_quotes WHERE id=(q->>'id')::uuid)<>'expired' THEN RAISE EXCEPTION 'IDENTITY_OR_HISTORY_LOST'; END IF;
 IF public.direct_order_public_amend(sid,secret,r,op,ctx->>'token',payload)<>v OR (SELECT count(*) FROM direct_order_amendments WHERE request_id=r)<>1 THEN RAISE EXCEPTION 'AMEND_RETRY_DUPLICATE'; END IF;
 BEGIN PERFORM public.direct_order_staff_quote_current(shop,r,0,NULL,'customer_direct',ctx->>'token'); RAISE EXCEPTION 'STALE_CASHIER_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_AMENDMENT_STALE' THEN RAISE; END IF; END;
 BEGIN PERFORM public.direct_order_public_amend(sid,secret,r,gen_random_uuid(),ctx->>'token',payload); RAISE EXCEPTION 'STALE_EDIT_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_AMENDMENT_STALE' THEN RAISE; END IF; END;
 BEGIN PERFORM public.direct_order_public_amend(sid,secret,r,op,ctx->>'token',jsonb_set(payload,'{existing,0,quantity}','3')); RAISE EXCEPTION 'RETRY_CHANGED_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_AMENDMENT_RETRY_CHANGED' THEN RAISE; END IF; END;
 BEGIN PERFORM public.direct_order_public_amendment_context(sid,repeat('f',64),r); RAISE EXCEPTION 'SECRET_BYPASS'; EXCEPTION WHEN OTHERS THEN IF SQLERRM='SECRET_BYPASS' THEN RAISE; END IF; END;
 ctx:=public.direct_order_public_amendment_context(sid,secret,r);
 q:=public.direct_order_staff_quote_current(shop,r,0,NULL,'customer_direct',ctx->>'token');
 BEGIN PERFORM public.direct_order_public_amend(sid,secret,r,gen_random_uuid(),ctx->>'token',payload); RAISE EXCEPTION 'QUOTE_RACE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_AMENDMENT_STALE' THEN RAISE; END IF; END;
 ctx:=public.direct_order_public_amendment_context(sid,secret,r);
 payload:=jsonb_build_object('existing',jsonb_build_array(jsonb_build_object('id',item_id,'quantity',1)), 'additions',jsonb_build_array(jsonb_build_object('menu_item_id',menu_id,'quantity',1)));
 v:=public.direct_order_public_amend(sid,secret,r,gen_random_uuid(),ctx->>'token',payload);
 IF (SELECT count(*) FROM direct_order_request_items WHERE request_id=r)<>2 OR (v->'amounts'->>'final_total')::numeric<>216000 THEN RAISE EXCEPTION 'SAME_MENU_ADDITION_FAILED'; END IF;
 q:=public.direct_order_staff_quote_current(shop,r,0,NULL,'customer_direct',public.direct_order_edit_token(r));
 UPDATE direct_order_requests SET state='awaiting_payment_review' WHERE id=r;
 BEGIN PERFORM public.direct_order_public_amendment_context(sid,secret,r); RAISE EXCEPTION 'PAYMENT_REVIEW_EDIT_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_AMENDMENT_NOT_ALLOWED' THEN RAISE; END IF; END;
 UPDATE direct_order_requests SET state='quoted' WHERE id=r;
 ctx:=public.direct_order_public_amendment_context(sid,secret,r);
 SELECT jsonb_build_object('existing',jsonb_agg(jsonb_build_object('id',id,'quantity',0)), 'additions','[]'::jsonb) INTO payload FROM direct_order_request_items WHERE request_id=r;
 v:=public.direct_order_public_amend(sid,secret,r,gen_random_uuid(),ctx->>'token',payload);
 IF v->>'state'<>'cancelled' OR (SELECT count(*) FROM direct_order_amendments WHERE request_id=r)<>3 THEN RAISE EXCEPTION 'CANCELLATION_HISTORY_WRONG'; END IF;
 BEGIN PERFORM public.direct_order_public_amendment_context(sid,secret,r); RAISE EXCEPTION 'CANCELLED_EDIT_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_AMENDMENT_NOT_ALLOWED' THEN RAISE; END IF; END;
 RAISE NOTICE 'AMENDMENTS=PASS identity quantities additions repricing quote_history stale_cashier stale_edit quote_race replay changed_retry secret payment_review cancellation';
END $$;
DO $combo$
DECLARE shop uuid:='d1000000-0000-4000-8000-000000000002'; sid uuid; secret text:=repeat('b',64); rid uuid; line public.direct_order_request_items%ROWTYPE; payload jsonb; v jsonb; ctx jsonb;
BEGIN
 INSERT INTO direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(shop,secret,'vi') RETURNING id INTO sid;
 payload:=jsonb_build_object('locale','vi','fulfillment_type','delivery','diner_count',1,'utensils_requested',true,
 'address',jsonb_build_object('customer_name','Test','customer_phone','0901234567','formatted_address','123 Test Street','address_source','manual'),
 'items',jsonb_build_array(jsonb_build_object('menu_item_id','c5000000-0000-4000-8000-000000000001','quantity',1,'combo_drink_choices',
 jsonb_build_array('c5000000-0000-4000-8000-000000000003','c5000000-0000-4000-8000-000000000004'))));
 v:=public.direct_order_public_submit_v3(sid,secret,gen_random_uuid(),payload); rid:=(v->>'request_id')::uuid;
 SELECT * INTO line FROM direct_order_request_items WHERE request_id=rid;
 ctx:=public.direct_order_public_amendment_context(sid,secret,rid);
 v:=public.direct_order_public_amend(sid,secret,rid,gen_random_uuid(),ctx->>'token',jsonb_build_object('existing',jsonb_build_array(jsonb_build_object('id',line.id,'quantity',2)),'additions','[]'::jsonb));
 IF NOT EXISTS(SELECT 1 FROM direct_order_request_items i WHERE i.id=line.id AND i.quantity=2 AND i.unit_price=line.unit_price AND jsonb_array_length(i.combo_drink_choices)=4
 AND i.vat_profile_snapshot=public.menu_vat_profile(i.menu_item_id,shop,i.combo_components,i.quantity)) THEN RAISE EXCEPTION 'COMBO_RESIZE_SNAPSHOT_WRONG'; END IF;
 ctx:=public.direct_order_public_amendment_context(sid,secret,rid);
 v:=public.direct_order_public_amend(sid,secret,rid,gen_random_uuid(),ctx->>'token',jsonb_build_object('existing',jsonb_build_array(jsonb_build_object('id',line.id,'quantity',1)),'additions','[]'::jsonb));
 IF NOT EXISTS(SELECT 1 FROM direct_order_request_items i WHERE i.id=line.id AND i.combo_components=line.combo_components AND i.combo_drink_choices=line.combo_drink_choices AND i.vat_profile_snapshot=line.vat_profile_snapshot) THEN RAISE EXCEPTION 'COMBO_REDUCTION_LOST_SNAPSHOT'; END IF;
 ctx:=public.direct_order_public_amendment_context(sid,secret,rid);
 v:=public.direct_order_public_amend(sid,secret,rid,gen_random_uuid(),ctx->>'token',jsonb_build_object('existing',jsonb_build_array(jsonb_build_object('id',line.id,'quantity',1)), 'additions',payload->'items'));
 ctx:=public.direct_order_public_amendment_context(sid,secret,rid);
 SELECT jsonb_build_object('existing',jsonb_agg(jsonb_build_object('id',i.id,'quantity',2)),'additions','[]'::jsonb) INTO payload FROM direct_order_request_items i WHERE request_id=rid;
 v:=public.direct_order_public_amend(sid,secret,rid,gen_random_uuid(),ctx->>'token',payload);
 IF (SELECT count(*) FROM direct_order_request_items WHERE request_id=rid AND quantity=2)<>2 THEN RAISE EXCEPTION 'DUPLICATE_COMBO_BATCH_COLLAPSED_LINES'; END IF;
 IF public.direct_order_staff_detail_v9(shop,rid)->'amendments'->0 ? 'input' THEN RAISE EXCEPTION 'UNBOUNDED_AUDIT_RESPONSE'; END IF;
 RAISE NOTICE 'AMENDMENT_COMBO=PASS stable_line_id selected_drinks vat_snapshot increase decrease duplicate_choice_batch';
END $combo$;
DO $isolation$
DECLARE shop uuid:='d1000000-0000-4000-8000-000000000002'; r uuid; other uuid; sid uuid; secret text; ctx jsonb; line uuid; q jsonb; payload jsonb;
BEGIN
 r:=guide_test.request(); other:=guide_test.request();
 SELECT session_id INTO sid FROM direct_order_requests WHERE id=r;
 SELECT secret_hash INTO secret FROM direct_order_sessions WHERE id=sid;
 SELECT id INTO line FROM direct_order_request_items WHERE request_id=r;
 q:=public.direct_order_staff_quote_with_payment_mode(shop,r,0,NULL,'customer_direct');
 ctx:=public.direct_order_public_amendment_context(sid,secret,r);
 BEGIN PERFORM public.direct_order_public_amendment_context(sid,secret,other); RAISE EXCEPTION 'OTHER_ORDER_ACCESS';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_REQUEST_NOT_FOUND' THEN RAISE; END IF; END;
 payload:=jsonb_build_object('existing',jsonb_build_array(jsonb_build_object('id',(SELECT id FROM direct_order_request_items WHERE request_id=other LIMIT 1),'quantity',1)),'additions','[]'::jsonb);
 BEGIN PERFORM public.direct_order_public_amend(sid,secret,r,gen_random_uuid(),ctx->>'token',payload); RAISE EXCEPTION 'FOREIGN_LINE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_AMENDMENT_INPUT_INVALID' THEN RAISE; END IF; END;
 IF (SELECT status FROM direct_order_quotes WHERE id=(q->>'id')::uuid)<>'active' THEN RAISE EXCEPTION 'FAILED_EDIT_EXPIRED_QUOTE'; END IF;
 UPDATE direct_order_requests SET state='approved' WHERE id=r;
 BEGIN PERFORM public.direct_order_public_amendment_context(sid,secret,r); RAISE EXCEPTION 'PAID_EDIT_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_AMENDMENT_NOT_ALLOWED' THEN RAISE; END IF; END;
 IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.direct_order_amendments'::regclass)
 OR has_table_privilege('anon','public.direct_order_amendments','SELECT')
 OR has_function_privilege('authenticated','public.direct_order_public_amend(uuid,text,uuid,uuid,text,jsonb)','EXECUTE')
 THEN RAISE EXCEPTION 'AMENDMENT_PUBLIC_ACCESS'; END IF;
 PERFORM public.direct_order_staff_list_v6(shop,ARRAY['customer_pending','customer_paid'],200,NULL);
 RAISE NOTICE 'AMENDMENT_ISOLATION=PASS session order line tenant_permissions rls failed_edit_rollback paid_state batched_list';
END $isolation$;
ROLLBACK;
