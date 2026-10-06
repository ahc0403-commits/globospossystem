BEGIN;
-- Match the production FK, which the broader inventory fixture omits.
DELETE FROM public.audit_logs;
ALTER TABLE public.audit_logs ADD CONSTRAINT test_procurement_actor_auth_fkey
 FOREIGN KEY(actor_id) REFERENCES auth.users(id);
INSERT INTO auth.users VALUES(test_uuid(98101));
INSERT INTO public.users(id,auth_id,role,restaurant_id,primary_store_id,is_active,full_name)
 VALUES(test_uuid(98102),test_uuid(98101),'super_admin',test_uuid(101),test_uuid(101),true,'Distinct profile administrator');
UPDATE public.restaurants SET short_code='BT' WHERE id=test_uuid(101);
DO $test$
DECLARE requirement public.store_fixed_account_requirements%rowtype;
 again public.store_fixed_account_requirements%rowtype;
BEGIN
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(98101)::text,true);
 ASSERT test_uuid(98101)<>test_uuid(98102);
 requirement:=public.admin_prepare_procurement_store_account(test_uuid(101),
  'bt_pr_audit','inventory_orderer','Shared PR team','Owner requested PR account');
 again:=public.admin_prepare_procurement_store_account(test_uuid(101),
  'bt_pr_audit','inventory_orderer','Shared PR team','Idempotent preparation');
 ASSERT requirement.id=again.id AND again.provisioned_user_id IS NULL;
 ASSERT (SELECT count(*) FROM public.audit_logs
  WHERE entity_id=requirement.id AND action='prepare_procurement_account'
   AND actor_id=test_uuid(98101)
   AND details->>'actor_profile_id'=test_uuid(98102)::text
   AND details->>'auth_provisioned'='false')=2;
 ASSERT NOT EXISTS(SELECT 1 FROM public.users WHERE fixed_account_code='bt_pr_audit'),
  'Requirement preparation must not create or bypass native Auth provisioning';
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 PERFORM public.test_expect_error(format(
  'SELECT public.admin_prepare_procurement_store_account(%L,%L,%L,%L,%L)',
  test_uuid(101),'bt_pr_denied','inventory_orderer','PR team','Forbidden'),
  'PROCUREMENT_ACCOUNT_PREPARATION_FORBIDDEN');
 ASSERT NOT EXISTS(SELECT 1 FROM public.store_fixed_account_requirements WHERE account_code='bt_pr_denied');
 ASSERT (SELECT count(*) FROM public.audit_logs)=2;
END $test$;
ROLLBACK;
