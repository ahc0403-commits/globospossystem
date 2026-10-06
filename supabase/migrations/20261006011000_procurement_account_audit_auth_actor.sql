BEGIN;
-- production-gate: self-verifying
-- audit_logs.actor_id references auth.users; a POS profile has its own UUID.
-- Keep the active profile check and retain its ID separately in audit details.
DO $patch$
DECLARE definition text;needle text;replacement text;
BEGIN
 definition:=pg_get_functiondef('public.admin_prepare_procurement_store_account(uuid,text,text,text,text)'::regprocedure);
 needle:=$old$VALUES(v_actor_id,'prepare_procurement_account','store_fixed_account_requirement',
    v_result.id,jsonb_build_object('store_id',p_store_id,'account_code',v_code,
      'role',p_role,'reason',btrim(p_reason),'auth_provisioned',false));$old$;
 replacement:=$new$VALUES(auth.uid(),'prepare_procurement_account','store_fixed_account_requirement',
    v_result.id,jsonb_build_object('store_id',p_store_id,'account_code',v_code,
      'role',p_role,'reason',btrim(p_reason),'auth_provisioned',false,
      'actor_profile_id',v_actor_id));$new$;
 IF position(needle IN definition)=0 THEN
  RAISE EXCEPTION 'PROCUREMENT_ACCOUNT_AUDIT_ACTOR_PATCH_MISMATCH';
 END IF;
 EXECUTE replace(definition,needle,replacement);
END $patch$;

DO $verify$
DECLARE definition text;
BEGIN
 definition:=pg_get_functiondef('public.admin_prepare_procurement_store_account(uuid,text,text,text,text)'::regprocedure);
 IF position('VALUES(auth.uid(),''prepare_procurement_account''' IN definition)=0
  OR position('''actor_profile_id'',v_actor_id' IN definition)=0
  OR position('IF NOT public.is_super_admin()' IN definition)=0
  OR position('WHERE auth_id=auth.uid() AND is_active' IN definition)=0
  OR has_function_privilege('anon','public.admin_prepare_procurement_store_account(uuid,text,text,text,text)','EXECUTE')
  OR has_function_privilege('service_role','public.admin_prepare_procurement_store_account(uuid,text,text,text,text)','EXECUTE')
  OR NOT has_function_privilege('authenticated','public.admin_prepare_procurement_store_account(uuid,text,text,text,text)','EXECUTE')
 THEN RAISE EXCEPTION 'PROCUREMENT_ACCOUNT_AUDIT_ACTOR_CONTRACT_FAILED';END IF;
END $verify$;
COMMIT;
