BEGIN;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS is_sso_user boolean NOT NULL DEFAULT false;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
UPDATE public.brands SET short_code='LAB',service_charge_enabled=false WHERE id='91000000-0000-4000-8000-000000000003';
DO $$ DECLARE
 request uuid:=gen_random_uuid(); shop uuid; lease jsonb; status jsonb; employee store_employees; destination uuid; menu uuid; tab uuid; ord orders; hash text; evidence_id uuid:=gen_random_uuid(); payment payments;
 brand uuid:='91000000-0000-4000-8000-000000000003'; entity uuid:='91000000-0000-4000-8000-000000000004';
BEGIN
 ASSERT (SELECT state='active' AND legacy_operational FROM store_lifecycle WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849');
 ASSERT (SELECT state='active' AND legacy_operational FROM store_lifecycle WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c');
 shop:=public.admin_register_store_v1(request,jsonb_build_object('name','Opening branch','brand',brand,'entity',entity));
 status:=public.admin_get_store_lifecycle_v1(shop);
 ASSERT status->'lifecycle'->>'state'='preparing' AND status->>'business_ready'='false';
 BEGIN INSERT INTO orders(restaurant_id,status) VALUES(shop,'pending'); RAISE EXCEPTION 'unopened intake accepted'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='STORE_NOT_OPEN_FOR_NEW_ORDERS',SQLERRM; END;
 BEGIN UPDATE restaurants SET short_code='EDITED' WHERE id=shop; RAISE EXCEPTION 'identity bypass'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='STORE_REGISTERED_IDENTITY_FROZEN',SQLERRM; END;
 BEGIN PERFORM public.admin_transition_store_lifecycle_v1(shop,0,'active',status->>'source_hash','Opening'); RAISE EXCEPTION 'incomplete opened'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='STORE_OPENING_NOT_READY',SQLERRM; END;
 lease:=public.claim_store_onboarding_v1(request);
 INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at,raw_app_meta_data)
 SELECT gen_random_uuid(),a->>'account_code'||'@globos.world','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now(),
 jsonb_build_object('store_onboarding',jsonb_build_object('code',a->>'account_code','role',a->>'role','type',a->>'account_type','scope',a->>'scope','owner_id',a->>'owner_id'))
 FROM jsonb_array_elements(lease->'items')a WHERE NOT (a->>'auth_exists')::boolean;
 PERFORM public.finish_store_onboarding_v1(request,(lease->>'lease_id')::uuid);
 employee:=public.create_store_employee(shop,'Opening manager','manager');
 BEGIN PERFORM public.admin_record_store_handover_v1(evidence_id,shop,employee.id,'Fixture credential handover'); RAISE EXCEPTION 'temporary password accepted'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='HANDOVER_ACCOUNTS_NOT_READY',SQLERRM; END;
 -- The Auth password flow is separately tested. This fixture represents completed rotations.
 UPDATE users SET must_change_password=false WHERE restaurant_id=shop;
 PERFORM public.admin_record_store_handover_v1(evidence_id,shop,employee.id,'Fixture credential handover');
 PERFORM public.admin_record_store_handover_v1(evidence_id,shop,employee.id,'Fixture credential handover');
 ASSERT (SELECT count(*)=1 FROM store_credential_handovers WHERE id=evidence_id);
 INSERT INTO tables(restaurant_id,table_number,floor_label) VALUES(shop,'101','HALL') RETURNING id INTO tab;
 INSERT INTO printer_destinations(restaurant_id,name,ip,port,purpose,is_active) VALUES(shop,'Cashier','192.0.2.10',9100,'receipt',true) RETURNING id INTO destination;
 PERFORM public.admin_enqueue_store_opening_tests(shop,ARRAY[destination],gen_random_uuid());
 -- A simulated print agent acknowledges the actual queued test job.
 UPDATE print_jobs SET status='done' WHERE restaurant_id=shop AND destination_id=destination;
 PERFORM public.approve_invoice_mapping_policy(shop,entity,'opening-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated fixture');
 INSERT INTO menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price) VALUES(shop,'Opening meal','Món thử','Phần',10000) RETURNING id INTO menu;
 status:=public.admin_get_store_lifecycle_v1(shop);
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_each(status->'checks')c WHERE c.key<>'field_verification' AND c.value<>'true'::jsonb),status::text;
 hash:=status->>'source_hash';
 PERFORM public.admin_record_store_verification_v1(gen_random_uuid(),shop,hash,'Fixture: real output and kitchen/hall handoff verified');
 status:=public.admin_get_store_lifecycle_v1(shop);
 ASSERT status->>'business_ready'='true',status::text;
 UPDATE menu_items SET price=11000 WHERE id=menu;
 BEGIN PERFORM public.admin_transition_store_lifecycle_v1(shop,0,'active',hash,'Opening'); RAISE EXCEPTION 'stale evidence accepted'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='STORE_OPENING_NOT_READY',SQLERRM; END;
 status:=public.admin_get_store_lifecycle_v1(shop);
 ASSERT status->>'business_ready'='false','configuration change retained old verification';
 PERFORM public.admin_record_store_verification_v1(gen_random_uuid(),shop,status->>'source_hash','Fixture retest after menu change');
 status:=public.admin_get_store_lifecycle_v1(shop);
 status:=public.admin_transition_store_lifecycle_v1(shop,0,'active',status->>'source_hash','Opening');
 ASSERT status->'lifecycle'->>'state'='active';
 ord:=public.create_order(shop,tab,jsonb_build_array(jsonb_build_object('menu_item_id',menu,'quantity',1)));
 UPDATE orders SET status='serving' WHERE id=ord.id;
 UPDATE order_items SET status='served' WHERE order_id=ord.id;
 status:=public.admin_transition_store_lifecycle_v1(shop,1,'suspended',status->>'source_hash','Pause intake while completing current orders');
 BEGIN INSERT INTO orders(restaurant_id,status) VALUES(shop,'pending'); RAISE EXCEPTION 'suspended intake accepted'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='STORE_NOT_OPEN_FOR_NEW_ORDERS',SQLERRM; END;
 payment:=public.process_payment(ord.id,shop,11880,'CASH');
 ASSERT (SELECT o.status='completed' FROM orders o WHERE o.id=ord.id),'suspension broke existing payment';
 ASSERT (SELECT amount=11880 FROM payments WHERE id=payment.id);
 ASSERT EXISTS(SELECT 1 FROM meinvoice_jobs WHERE order_id=ord.id),'async invoice lost';
 UPDATE users SET password_change_generation=password_change_generation+1 WHERE restaurant_id=shop AND role='cashier';
 status:=public.admin_get_store_lifecycle_v1(shop);
 ASSERT status->'checks'->>'credential_handover'='false','password generation did not invalidate handover';
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000006',true);
 BEGIN PERFORM public.admin_get_store_lifecycle_v1(shop); RAISE EXCEPTION 'cross store readiness exposed'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM<>'cross store readiness exposed'; END;
END $$;
SELECT 'STORE_LIFECYCLE_READINESS=PASS';
ROLLBACK;
