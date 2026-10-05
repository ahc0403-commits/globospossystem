BEGIN;
UPDATE public.restaurants SET short_code=CASE id WHEN test_uuid(101) THEN 'BT' ELSE 'BD' END;
INSERT INTO public.tax_entity VALUES(test_uuid(801));
INSERT INTO public.legal_entity_fixed_account_requirements(tax_entity_id,account_code,display_name,provisioned_user_id)
 VALUES(test_uuid(801),'account','Existing legal verifier',test_uuid(4));
DO $test$
DECLARE requirement public.store_fixed_account_requirements%rowtype;again public.store_fixed_account_requirements%rowtype;
 buyer jsonb:=jsonb_build_object('system','office','subject_id',test_uuid(9901),'store_id',test_uuid(101),'can_manage',true,'can_office_approve',true);
 payload jsonb;r jsonb;prior jsonb;request uuid;version integer;
BEGIN
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 PERFORM public.test_expect_error(format('SELECT public.admin_prepare_procurement_store_account(%L,%L,%L,%L,%L)',
  test_uuid(101),'bt_pr1','inventory_orderer','Shared requester','Rollout'),'PROCUREMENT_ACCOUNT_PREPARATION_FORBIDDEN');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(10)::text,true);
 requirement:=public.admin_prepare_procurement_store_account(test_uuid(101),'bt_verify1','inventory_accounting','BT shared verifier','User requested separate verifier');
 again:=public.admin_prepare_procurement_store_account(test_uuid(101),'bt_verify1','inventory_accounting','BT shared verifier','Idempotent preparation');
 ASSERT requirement.id=again.id AND again.provisioned_user_id IS NULL;
 ASSERT again.scope='store' AND again.role='inventory_accounting';
 ASSERT (SELECT provisioned_user_id FROM public.legal_entity_fixed_account_requirements WHERE account_code='account')=test_uuid(4);
 PERFORM public.test_expect_error(format('SELECT public.admin_prepare_procurement_store_account(%L,%L,%L,%L,%L)',
  test_uuid(102),'bt_verify1','inventory_accounting','Verifier','Wrong scope'),'PROCUREMENT_ACCOUNT_INPUT_INVALID');
 PERFORM public.test_expect_error(format('SELECT public.admin_prepare_procurement_store_account(%L,%L,%L,%L,%L)',
  test_uuid(101),'bt_verify1','inventory_orderer','Verifier','Wrong role'),'PROCUREMENT_ACCOUNT_IDENTITY_CONFLICT');
 PERFORM public.test_expect_error(format('SELECT public.admin_prepare_procurement_store_account(%L,%L,%L,%L,%L)',
  test_uuid(101),'bt_buyer','super_admin','Buyer','Bad escalation'),'PROCUREMENT_ACCOUNT_INPUT_INVALID');
 ASSERT NOT EXISTS(SELECT 1 FROM auth.users a JOIN public.users u ON u.auth_id=a.id WHERE u.fixed_account_code='bt_verify1'), 'Preparation never creates Auth';
 INSERT INTO auth.users VALUES(test_uuid(98001));
 INSERT INTO public.users(id,auth_id,role,restaurant_id,primary_store_id,full_name,account_type,fixed_account_code)
  VALUES(test_uuid(98001),test_uuid(98001),'inventory_accounting',test_uuid(101),test_uuid(101),'BT shared verifier','inventory_accounting','bt_verify1');
 INSERT INTO public.user_store_access VALUES(test_uuid(98001),test_uuid(101),true);
 UPDATE public.store_fixed_account_requirements SET provisioned_user_id=test_uuid(98001) WHERE id=requirement.id;
 ASSERT (SELECT count(*) FROM public.user_accessible_stores(test_uuid(98001)))=1;
 ASSERT NOT EXISTS(SELECT 1 FROM public.user_tax_entity_access WHERE user_id=test_uuid(98001));
 ASSERT EXISTS(SELECT 1 FROM public.user_accessible_stores(test_uuid(4)) s(id) WHERE id=test_uuid(103)), 'Legacy legal-entity verifier retains its access';
 PERFORM public.test_expect_error(format('SELECT public.admin_prepare_procurement_store_account(%L,%L,%L,%L,%L)',
  test_uuid(101),'bt_verify1','inventory_accounting','Rename provisioned identity','No rename'),'PROCUREMENT_ACCOUNT_PROVISIONED_IDENTITY_IMMUTABLE');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(98001)::text,true);
 ASSERT public.can_verify_inventory_receipt(test_uuid(101));
 ASSERT NOT public.can_verify_inventory_receipt(test_uuid(103));
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 payload:=jsonb_build_object('account_kind','shared_role','system','pos','subject_id',test_uuid(1),
  'person_id',test_uuid(99999),'employee_confirmation',jsonb_build_object('name','Fake employee'),
  'display_name','Fake name','stage','requester','valid_from',now()-interval '1 day',
  'valid_until',now()+interval '365 days','reason','Shared ID; no deputy');
 r:=public.procurement_command(test_uuid(101),'assign_principal',NULL,0,'shared-requester',payload,buyer);
 ASSERT r->>'account_kind'='shared_role' AND r->>'person_id' IS NULL;
 ASSERT r->>'display_name'='Orderer A';
 prior:=public.procurement_command(test_uuid(101),'assign_principal',NULL,0,'shared-requester',payload,buyer);
 ASSERT r=prior;
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,NULL,0,%L,%L::jsonb,%L::jsonb)',
  test_uuid(101),'assign_principal','shared-requester',payload||'{"reason":"Different retry"}'::jsonb,buyer),'PROCUREMENT_RETRY_MISMATCH');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,NULL,0,%L,%L::jsonb,%L::jsonb)',
  test_uuid(101),'assign_principal','shared-person-conflict',payload||'{"account_kind":"person"}'::jsonb,buyer),'PROCUREMENT_PRINCIPAL_IDENTITY_CONFLICT');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,NULL,0,%L,%L::jsonb,%L::jsonb)',
  test_uuid(101),'assign_principal','shared-foreign',payload||jsonb_build_object('subject_id',test_uuid(5)),buyer),'PROCUREMENT_PRINCIPAL_REQUIRED');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,NULL,0,%L,%L::jsonb,%L::jsonb)',
  test_uuid(101),'assign_principal','shared-wrong-stage',payload||'{"stage":"store"}'::jsonb,buyer),'PROCUREMENT_PRINCIPAL_STAGE_FORBIDDEN');
 payload:=payload||jsonb_build_object('system','office','subject_id',test_uuid(98002),'stage','purchase');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,NULL,0,%L,%L::jsonb,%L::jsonb)',
  test_uuid(101),'assign_principal','shared-office-unverified',payload,buyer),'PROCUREMENT_PRINCIPAL_REQUIRED');
 payload:=payload||jsonb_build_object('principal_confirmation',jsonb_build_object('subject_id',test_uuid(98002),
  'pos_store_id',test_uuid(101),'stage','purchase','can_assign_stage',true,'display_name','Verified Office purchase account'));
 r:=public.procurement_command(test_uuid(101),'assign_principal',NULL,0,'shared-office',payload,buyer);
 ASSERT r->>'person_id' IS NULL AND r->>'display_name'='Verified Office purchase account';
 ASSERT NOT public.procurement_same_person(jsonb_build_object('system','pos','subject_id',test_uuid(1)),
  jsonb_build_object('system','office','subject_id',test_uuid(98002)),test_uuid(101)), 'Shared accounts do not assert human identity';
 ASSERT public.procurement_same_person(jsonb_build_object('system','pos','subject_id',test_uuid(1)),
  jsonb_build_object('system','pos','subject_id',test_uuid(1)),test_uuid(101)), 'Same account still cannot approve itself';
 SELECT row_version INTO version FROM public.procurement_store_policies WHERE restaurant_id=test_uuid(101);
 PERFORM public.procurement_command(test_uuid(101),'configure',NULL,version,'shared-policy',
  '{"enabled":true,"three_stage_required":true,"high_value_amount":1000000,"max_price_increase_percent":20,"quantity_review_multiplier":100}',buyer);
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 r:=public.procurement_command(test_uuid(101),'create_request',NULL,0,'shared-pr',
  jsonb_build_object('reason','Shared requester','requested_delivery_date',current_date+2,
   'lines',jsonb_build_array(jsonb_build_object('product_id',test_uuid(301),'quantity',10,'unit','g'))));
 request:=(r->>'id')::uuid;
 r:=public.procurement_command(test_uuid(101),'submit_request',request,1,'shared-submit');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L)',
  test_uuid(101),'store_approve',request,'shared-self'),'PROCUREMENT_SELF_APPROVAL_FORBIDDEN');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 r:=public.procurement_command(test_uuid(101),'store_approve',request,2,'shared-sm');
 ASSERT r->>'status'='brand_review';
END $test$;
ROLLBACK;
