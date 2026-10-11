-- Synthetic, disposable recipient fixture only.
CREATE SCHEMA buyer_measurement;
CREATE TABLE buyer_measurement.scope(store_id uuid,order_id uuid,version bigint);
DO $test$
DECLARE f jsonb;shop uuid;r uuid;o uuid;v jsonb;again jsonb;version bigint;before_money jsonb;before_job jsonb;patch jsonb;
BEGIN
 f:=photo_test.create_request(true,'customer_direct');r:=(f->>'request_id')::uuid;shop:=(f->>'store_id')::uuid;
 UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
 PERFORM photo_test.approve(f);SELECT order_id INTO o FROM public.direct_order_financials WHERE request_id=r;
 SELECT jsonb_agg(to_jsonb(p)) INTO before_money FROM public.payments p WHERE order_id=o;
 SELECT jsonb_agg(to_jsonb(j)) INTO before_job FROM public.meinvoice_jobs j WHERE order_id=o;
 patch:=jsonb_build_object('buyer_number_type','vn_tax','buyer_number_value','0012345678-001','buyer_legal_name','Fixture Company',
 'buyer_address','Fixture address','buyer_email','fixture@example.invalid','buyer_phone','0900000000','buyer_unit_code','UNIT-01',
 'buyer_full_name','Fixture Buyer','buyer_email_cc','cc@example.invalid','buyer_id','001234567890','source_note','Keep note');
 v:=public.pos_save_buyer_information(shop,o,NULL,patch,true);version:=(v->>'buyer_version')::bigint;
 IF (v->>'gross_amount')::numeric<>(SELECT sum(COALESCE(amount_portion,amount)) FROM public.payments WHERE order_id=o AND is_revenue) THEN RAISE EXCEPTION 'POS_INTAKE_PAID_PORTION_MISMATCH'; END IF;
 IF v->>'buyer_number_value'<>'0012345678-001' OR v->>'buyer_unit_code'<>'UNIT-01' OR v->>'buyer_full_name'<>'Fixture Buyer' THEN RAISE EXCEPTION 'BUYER_FIELDS_LOST'; END IF;
 IF (SELECT invoice_details->>'pos_only' FROM public.direct_order_requests WHERE id=r)<>'true' OR (SELECT invoice_details->>'email_cc' FROM public.direct_order_requests WHERE id=r)<>'cc@example.invalid' THEN RAISE EXCEPTION 'BUYER_SOURCE_NOT_SYNCED'; END IF;
 BEGIN
  PERFORM public.pos_save_buyer_information(shop,o,version,patch||jsonb_build_object('buyer_number_value','1234567890-00'),true);RAISE EXCEPTION 'INVALID_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'POS_BUYER_NUMBER_INVALID' THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.pos_save_buyer_information(shop,o,version-1,patch,true);RAISE EXCEPTION 'STALE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'POS_BUYER_CHANGED' THEN RAISE; END IF; END;
 UPDATE public.red_invoice_intakes SET attachment_urls=ARRAY['https://fixture.invalid/evidence'] WHERE order_id=o;
 SELECT buyer_version INTO version FROM public.red_invoice_intakes WHERE order_id=o;
 again:=public.pos_save_buyer_information(shop,o,version,jsonb_build_object('buyer_address','Revised fixture address'),true);
 IF again->>'buyer_email_cc'<>'cc@example.invalid' OR again->>'buyer_id'<>'001234567890' OR again->'attachment_urls'<>jsonb_build_array('https://fixture.invalid/evidence') THEN RAISE EXCEPTION 'OPTIONALS_EVIDENCE_LOST'; END IF;
 -- Legacy NULL writers preserve optional fields; deliberate POS clearing works.
 UPDATE public.red_invoice_intakes SET buyer_unit_code=NULL,buyer_full_name=NULL,buyer_email_cc=NULL,buyer_id=NULL WHERE order_id=o;
 IF (SELECT buyer_unit_code FROM public.red_invoice_intakes WHERE order_id=o)<>'UNIT-01' THEN RAISE EXCEPTION 'LEGACY_OPTIONALS_WIPED'; END IF;
 SELECT buyer_version INTO version FROM public.red_invoice_intakes WHERE order_id=o;
 again:=public.pos_save_buyer_information(shop,o,version,jsonb_build_object('buyer_email_cc',''),true);
 IF again->>'buyer_email_cc' IS NOT NULL THEN RAISE EXCEPTION 'EXPLICIT_CLEAR_FAILED'; END IF;
 PERFORM public.direct_order_sync_invoice_batch(shop,r);
 IF (SELECT buyer_address FROM public.red_invoice_intakes WHERE order_id=o)<>'Revised fixture address' OR (SELECT buyer_unit_code FROM public.red_invoice_intakes WHERE order_id=o)<>'UNIT-01' THEN RAISE EXCEPTION 'LATER_SYNC_REVERTED_EDIT'; END IF;
 IF before_money IS DISTINCT FROM (SELECT jsonb_agg(to_jsonb(p)) FROM public.payments p WHERE order_id=o)
 OR before_job IS DISTINCT FROM (SELECT jsonb_agg(to_jsonb(j)) FROM public.meinvoice_jobs j WHERE order_id=o) THEN RAISE EXCEPTION 'POS_EDIT_CHANGED_MONEY_OR_MISA'; END IF;
 -- Household, personal and foreign identifiers stay strings.
 FOREACH patch IN ARRAY ARRAY[jsonb_build_object('buyer_number_type','household_id','buyer_number_value','001234567890'),
 jsonb_build_object('buyer_number_type','personal_id','buyer_number_value','001234567890','buyer_full_name','Person'),
 jsonb_build_object('buyer_number_type','passport','buyer_number_value','A00123456','buyer_full_name','Foreign person'),
 jsonb_build_object('buyer_number_type','foreign_tax','buyer_number_value','DE-0012345')] LOOP
  SELECT buyer_version INTO version FROM public.red_invoice_intakes WHERE order_id=o;
  again:=public.pos_save_buyer_information(shop,o,version,patch,true);
  IF again->>'buyer_number_value'<>patch->>'buyer_number_value' THEN RAISE EXCEPTION 'IDENTIFIER_CHANGED'; END IF;
 END LOOP;
 UPDATE public.users SET restaurant_id='d1000000-0000-4000-8000-000000000001' WHERE auth_id=auth.uid();
 BEGIN PERFORM public.pos_save_buyer_information(shop,o,version,patch,true);RAISE EXCEPTION 'FOREIGN_STORE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'STORE_ACCESS_FORBIDDEN' THEN RAISE; END IF; END;
 UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
 INSERT INTO buyer_measurement.scope SELECT shop,o,buyer_version FROM public.red_invoice_intakes WHERE order_id=o;
 RAISE NOTICE 'POS_BUYER_FIELDS_VALIDATION_OPTIONALS_SOURCE_ACCESS_MONEY_MISA=PASS';
END; $test$;
DO $$ DECLARE v text;BEGIN
 FOREACH v IN ARRAY ARRAY['123456789','12345678901','1234567890-000','1234567890-01','1234567890-001-002','123456789a'] LOOP
  IF public.pos_buyer_number_issue('vn_tax',v) IS NULL THEN RAISE EXCEPTION 'BAD_TAX_ACCEPTED: %',v; END IF;
 END LOOP;
 IF public.pos_buyer_number_issue('vn_tax','0012345678') IS NOT NULL OR public.pos_buyer_number_issue('personal_id','001234567890') IS NOT NULL
 OR public.pos_buyer_number_issue('household_id','00123456789') IS NULL OR public.pos_buyer_number_issue('passport','P0123') IS NOT NULL THEN RAISE EXCEPTION 'FORMAT_DRIFT'; END IF;
END $$;
DO $$ DECLARE s record;v jsonb;shop uuid;BEGIN
 IF to_regclass('buyer_legacy.scopes') IS NULL THEN RETURN; END IF;
 FOR s IN SELECT * FROM buyer_legacy.scopes LOOP
  shop:=(s.fixture->>'store_id')::uuid;UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
  IF s.kind='invalid_ready' THEN
   SELECT to_jsonb(i) INTO v FROM public.red_invoice_intakes i WHERE order_id=s.order_id;
   IF v->>'buyer_number_value'<>'00123456789-12' OR v->>'buyer_number_type'<>'vn_tax' THEN RAISE EXCEPTION 'LEGACY_RAW_REWRITTEN'; END IF;
   v:=public.pos_save_buyer_information(shop,s.order_id,(v->>'buyer_version')::bigint,jsonb_build_object('buyer_number_value','0012345678-001'),true);
   IF v->>'buyer_unit_code'<>'LEGACY-UNIT' OR v->>'buyer_email_cc'<>'cc@example.invalid' THEN RAISE EXCEPTION 'LEGACY_REPAIR_WIPED_OPTIONALS'; END IF;
  ELSE
   PERFORM photo_test.approve(s.fixture);
   IF NOT EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=(s.fixture->>'request_id')::uuid) THEN RAISE EXCEPTION 'FORMAT_BLOCKED_PAYMENT'; END IF;
  END IF;
 END LOOP;
 -- Restore the synthetic actor for the independent-session concurrency test.
 UPDATE public.users SET restaurant_id=(SELECT store_id FROM buyer_measurement.scope) WHERE auth_id=auth.uid();
 RAISE NOTICE 'LEGACY_RAW_REPAIR_GENERAL_PAYMENT=PASS';
END $$;
DO $$ DECLARE s record;o uuid;v jsonb;ids uuid[];jobs_before jsonb;money_before jsonb;BEGIN
 IF to_regclass('recipient_measurement.money_scopes') IS NULL THEN RETURN; END IF;
 SELECT * INTO s FROM recipient_measurement.money_scopes WHERE size=10;
 UPDATE public.users SET restaurant_id=s.restaurant_id WHERE auth_id=auth.uid();
 SELECT order_id INTO o FROM public.direct_order_financials WHERE request_id=s.request_id;
 SELECT array_agg(order_id) INTO ids FROM(SELECT order_id FROM public.direct_order_financials WHERE request_id=s.request_id
 UNION SELECT order_id FROM public.direct_order_payment_charges WHERE request_id=s.request_id AND order_id IS NOT NULL) targets;
 SELECT jsonb_agg(to_jsonb(j) ORDER BY id) INTO jobs_before FROM public.meinvoice_jobs j WHERE order_id=ANY(ids);
 SELECT jsonb_agg(to_jsonb(p) ORDER BY id) INTO money_before FROM public.payments p WHERE order_id=ANY(ids);
 SELECT to_jsonb(i) INTO v FROM public.red_invoice_intakes i WHERE order_id=o;
 v:=public.pos_save_buyer_information(s.restaurant_id,o,(v->>'buyer_version')::bigint,jsonb_build_object('buyer_address','Batch revised fixture address','buyer_email_cc','batch@example.invalid'),true);
 IF (SELECT count(*) FROM public.red_invoice_intakes WHERE order_id=ANY(ids) AND buyer_address='Batch revised fixture address' AND buyer_email_cc='batch@example.invalid')<>cardinality(ids)
 OR (SELECT count(*) FROM jsonb_object_keys(v->'related_buyer_versions'))<>cardinality(ids) THEN RAISE EXCEPTION 'RELATED_BUYER_BATCH_INCOMPLETE'; END IF;
 PERFORM public.direct_order_sync_invoice_batch(s.restaurant_id,s.request_id);
 IF jobs_before IS DISTINCT FROM (SELECT jsonb_agg(to_jsonb(j) ORDER BY id) FROM public.meinvoice_jobs j WHERE order_id=ANY(ids))
 OR money_before IS DISTINCT FROM (SELECT jsonb_agg(to_jsonb(p) ORDER BY id) FROM public.payments p WHERE order_id=ANY(ids)) THEN RAISE EXCEPTION 'BATCH_POS_EDIT_CHANGED_FINANCE'; END IF;
 UPDATE public.users SET restaurant_id=(SELECT store_id FROM buyer_measurement.scope) WHERE auth_id=auth.uid();
 RAISE NOTICE 'RELATED_POS_BUYER_BATCH=PASS orders=%',cardinality(ids);
END $$;
