BEGIN;
DO $test$
DECLARE page jsonb;next_page jsonb;r jsonb;record public.inventory_purchase_requests;seen bigint;
 sa uuid:=gen_random_uuid();sb uuid:=gen_random_uuid();buyer uuid:=gen_random_uuid();pr_auth uuid:=gen_random_uuid();pr_id uuid:=gen_random_uuid();sm_auth uuid:=gen_random_uuid();sm_id uuid:=gen_random_uuid();rc_auth uuid:=gen_random_uuid();rc_id uuid:=gen_random_uuid();rid uuid;role_name text;matrix_auth uuid;matrix_profile uuid;matrix_count integer:=0;matrix_actor jsonb;
BEGIN
 PERFORM set_config('app.procurement_write','true',true);
 UPDATE public.procurement_store_policies SET enabled=true,two_stage_required=true WHERE restaurant_id=test_uuid(101);
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 SELECT count(*) INTO seen FROM public.pos_live_events;
 INSERT INTO public.inventory_purchase_requests(id,restaurant_id,source,requested_delivery_date,reason,created_actor,status,approval_policy_version,created_at,submitted_at)
 VALUES(test_uuid(14001),test_uuid(101),'pos',current_date,'Old pending A',jsonb_build_object('system','pos','subject_id',test_uuid(1)),'submitted',3,now()-interval '90 days',now()-interval '80 days'),
 (test_uuid(14002),test_uuid(101),'pos',current_date,'Old pending B',jsonb_build_object('system','pos','subject_id',test_uuid(1)),'submitted',3,now()-interval '90 days',now()-interval '80 days'),
 (test_uuid(14003),test_uuid(101),'pos',current_date,'Own blocked',jsonb_build_object('system','pos','subject_id',test_uuid(2)),'submitted',3,now()-interval '90 days',now()-interval '79 days');
 ASSERT (SELECT count(*) FROM public.pos_live_events)=seen+1,'One event per store and statement, not per PR';
 page:=public.procurement_workspace_page(test_uuid(101),'{"request_scope":"mine","request_sort":"submitted","request_group":"pending","request_view":true,"limit":2}');
 ASSERT NOT(page->'actor' ? 'identity_people'),'Internal identity joins are never exported or saved as approval actors';
 ASSERT page->'requests'->0->>'id'=test_uuid(14001)::text,'All-time oldest pending first';
 ASSERT jsonb_array_length(page->'requests')=2 AND (page->>'request_has_more')::boolean;
 ASSERT (page->'approval_counts'->>'actionable')::integer>=2 AND (page->'approval_counts'->>'blocked')::integer>=1;
 next_page:=public.procurement_workspace_page(test_uuid(101),jsonb_build_object('request_scope','mine','request_sort','submitted','request_group','pending','request_view',true,'request_before',page->'requests'->1->>'submitted_at','request_before_id',page->'requests'->1->>'id','limit',2));
 ASSERT next_page->'requests'->0->>'id'=test_uuid(14003)::text,'Equal timestamps use ID cursor with no duplicate';
 ASSERT NOT(next_page->'requests'->0->'allowed_actions' ? 'store_approve'),'UI shares self-approval rejection';
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,1,%L,%L::jsonb)',test_uuid(101),'store_approve',test_uuid(14003),'inbox-self','{}'),'PROCUREMENT_SELF_APPROVAL_FORBIDDEN');
 PERFORM public.test_expect_error(format('SELECT public.procurement_workspace_page(%L,%L::jsonb)',test_uuid(102),'{}'),'PROCUREMENT_SCOPE_FORBIDDEN');
 UPDATE public.procurement_store_policies SET enabled=false WHERE restaurant_id=test_uuid(101);
 page:=public.procurement_workspace_page(test_uuid(101),'{"request_scope":"mine","request_sort":"submitted"}');
 ASSERT (page->'approval_counts'->>'actionable')::integer=0,'Disabled policy never advertises executable approvals';
 UPDATE public.procurement_store_policies SET enabled=true WHERE restaurant_id=test_uuid(101);
 -- Dynamic IDs and separate profile/Auth identities prove there is no production-ID list.
 INSERT INTO public.restaurants(id,brand_id,tax_entity_id,name) SELECT sa,brand_id,tax_entity_id,'Dynamic A' FROM public.restaurants WHERE id=test_uuid(101);
 INSERT INTO public.restaurants(id,brand_id,tax_entity_id,name) SELECT sb,brand_id,tax_entity_id,'Dynamic B' FROM public.restaurants WHERE id=test_uuid(101);
 INSERT INTO auth.users(id) VALUES(pr_auth),(sm_auth),(rc_auth);
 INSERT INTO public.users(id,auth_id,role,restaurant_id,primary_store_id,full_name,account_type,fixed_account_code)
 VALUES(pr_id,pr_auth,'inventory_orderer',sa,sa,'New PR','inventory_orderer','n1_pr1'),
 (sm_id,sm_auth,'store_admin',sa,sa,'New SM','store_manager','n1_sm1'),
 (rc_id,rc_auth,'inventory_orderer',sa,sa,'New receiving','inventory_orderer','n1_order');
 INSERT INTO public.user_store_access(user_id,store_id,source_type) VALUES(pr_id,sa,'direct'),(sm_id,sa,'direct'),(rc_id,sa,'direct');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);
 PERFORM public.admin_configure_store_workforce(sa,'N1','store_managed',1,'[{"account_code":"n1_pr1","account_type":"inventory_orderer","role":"inventory_orderer","display_name":"PR","scope":"store"},{"account_code":"n1_sm1","account_type":"store_manager","role":"store_admin","display_name":"SM","scope":"store"},{"account_code":"n1_order","account_type":"inventory_orderer","role":"inventory_orderer","display_name":"Receiver","scope":"store"}]');
 ASSERT NOT EXISTS(SELECT 1 FROM public.procurement_role_roster WHERE restaurant_id=sa),'Requirements are not fabricated Auth provisioning';
 UPDATE public.store_fixed_account_requirements q SET provisioned_user_id=u.id FROM public.users u WHERE q.store_id=sa AND q.account_code=u.fixed_account_code;
 ASSERT (SELECT count(*) FROM public.procurement_role_roster WHERE restaurant_id=sa AND system='pos')=3;
 ASSERT EXISTS(SELECT 1 FROM public.procurement_role_roster WHERE restaurant_id=sa AND subject_id=pr_auth AND stage='requester');
 ASSERT NOT EXISTS(SELECT 1 FROM public.procurement_role_roster WHERE restaurant_id=sa AND subject_id=pr_id),'Profile ID never used as login ID';
 ASSERT NOT EXISTS(SELECT 1 FROM public.procurement_store_policies WHERE restaurant_id=sa),'Missing Office connection cannot become ready';
 INSERT INTO public.legal_entity_fixed_account_requirements(tax_entity_id,account_code,account_type,role,display_name,scope,provisioned_user_id)
 SELECT tax_entity_id,'fixed_account_test','inventory_accounting','inventory_accounting','Fixed finance','legal_entity',test_uuid(4) FROM public.restaurants WHERE id=sa ON CONFLICT DO NOTHING;
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 page:=jsonb_build_array(jsonb_build_object('id',sa,'brand_id',(SELECT brand_id FROM public.restaurants WHERE id=sa),'tax_entity_id',(SELECT tax_entity_id FROM public.restaurants WHERE id=sa),'office_store_id',gen_random_uuid(),'principals',jsonb_build_array(jsonb_build_object('system','office','subject_id',buyer,'stage','purchase','display_name','Existing buyer','native_scope_confirmed',true))));
 PERFORM public.procurement_complete_office_onboarding(page);
 PERFORM public.procurement_complete_office_onboarding(page);
 ASSERT (SELECT count(*) FROM public.procurement_role_roster WHERE restaurant_id=sa)=4,'Retry does not duplicate principals';
 ASSERT (SELECT readiness FROM public.procurement_store_onboarding WHERE restaurant_id=sa) @> '{"requester":true,"store_manager":true,"receiver":true,"accounting":true}';
 ASSERT (SELECT enabled AND two_stage_required AND NOT three_stage_required FROM public.procurement_store_policies WHERE restaurant_id=sa);
 ASSERT EXISTS(SELECT 1 FROM public.user_store_access WHERE store_id=sa AND user_id=test_uuid(4));
 ASSERT NOT EXISTS(SELECT 1 FROM public.users WHERE role='inventory_accounting' AND restaurant_id=sa),'No central account created per store';
 PERFORM public.test_expect_error(format('SELECT public.admin_configure_store_workforce(%L,%L,%L,1,%L::jsonb)',sb,'N2','store_managed','[{"account_code":"n1_sm1","account_type":"store_manager","role":"store_admin","display_name":"collision","scope":"store"}]'),'STORE_ACCOUNT_CODE_ALREADY_ASSIGNED');
 PERFORM set_config('request.jwt.claim.role','authenticated',true);PERFORM set_config('request.jwt.claim.sub',pr_auth::text,true);
 ASSERT NOT public.can_create_inventory_purchase_order(sa),'Configured requester does not inherit receiving authority from a shared role name';
 PERFORM set_config('request.jwt.claim.sub',rc_auth::text,true);
 ASSERT public.can_create_inventory_purchase_order(sa),'Only the registered receiver has the receiving capability';
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 PERFORM public.procurement_complete_office_onboarding(jsonb_set(page,'{0,principals}','[]'));
 ASSERT NOT(SELECT office_connected FROM public.procurement_store_onboarding WHERE restaurant_id=sa),'Revoked native scope changes readiness';
 PERFORM public.procurement_complete_office_onboarding(page);
 ASSERT EXISTS(SELECT 1 FROM public.procurement_role_roster WHERE restaurant_id=sa AND subject_id=buyer AND stage='purchase' AND valid_until>now()),'A restored native grant reactivates the same identity';
 -- Local role matrix: 31 accounts, two scopes, inactive/cross-scope denial.
 FOR role_name IN SELECT role FROM(VALUES ('brand_admin',1),('cashier',3),('customer_display',2),('emergency_station',5),('inventory_accounting',1),('inventory_orderer',4),('kitchen',2),('photo_objet_master',2),('photo_objet_store_operator',6),('print_station',2),('store_admin',2),('super_admin',1)) roles(role,n) CROSS JOIN LATERAL generate_series(1,n) slot LOOP
  matrix_auth:=gen_random_uuid();matrix_profile:=gen_random_uuid();matrix_count:=matrix_count+1;
  INSERT INTO auth.users(id) VALUES(matrix_auth);
  INSERT INTO public.users(id,auth_id,role,restaurant_id,primary_store_id,full_name) VALUES(matrix_profile,matrix_auth,role_name,sa,sa,'Role matrix fixture');
  INSERT INTO public.user_store_access(user_id,store_id,source_type) VALUES(matrix_profile,sa,'direct');
  PERFORM set_config('request.jwt.claim.role','authenticated',true);PERFORM set_config('request.jwt.claim.sub',matrix_auth::text,true);
  IF role_name IN ('brand_admin','inventory_accounting','inventory_orderer','store_admin','super_admin') THEN
   matrix_actor:=public.procurement_actor(sa,NULL);
   ASSERT (matrix_actor->>'can_store_approve')::boolean=(role_name IN ('brand_admin','store_admin','super_admin'));
   ASSERT NOT COALESCE((matrix_actor->>'can_office_approve')::boolean,false),'POS account never impersonates Office buyer';
  ELSE
   PERFORM public.test_expect_error(format('SELECT public.procurement_workspace_page(%L,%L::jsonb)',sa,'{}'),'PROCUREMENT_SCOPE_FORBIDDEN');
  END IF;
  IF role_name<>'super_admin' THEN
   PERFORM public.test_expect_error(format('SELECT public.procurement_workspace_page(%L,%L::jsonb)',sb,'{}'),'PROCUREMENT_SCOPE_FORBIDDEN');
  END IF;
  UPDATE public.users SET is_active=false WHERE id=matrix_profile;
  PERFORM public.test_expect_error(format('SELECT public.procurement_workspace_page(%L,%L::jsonb)',sa,'{}'),'PROCUREMENT_SCOPE_FORBIDDEN');
 END LOOP;
 ASSERT matrix_count=31;
 RAISE NOTICE 'PASS: old pending inbox, stable cursor, self/scope guard, set-based feed, dynamic store IDs, real profile/Auth separation, idempotent staged onboarding and fixed finance identity and 31-account role matrix';
END $test$;
ROLLBACK;
