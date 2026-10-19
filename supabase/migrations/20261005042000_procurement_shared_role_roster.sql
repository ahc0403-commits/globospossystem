BEGIN;
-- production-gate: self-verifying
-- Shared role accounts identify an account, not a workforce employee.
ALTER TABLE public.procurement_role_roster ALTER COLUMN person_id DROP NOT NULL;
ALTER TABLE public.procurement_role_roster ADD COLUMN account_kind text NOT NULL DEFAULT 'person';
ALTER TABLE public.procurement_role_roster ADD CONSTRAINT procurement_roster_identity_check
 CHECK ((account_kind='person' AND person_id IS NOT NULL)
     OR (account_kind='shared_role' AND person_id IS NULL));

ALTER FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb)
 RENAME TO procurement_person_roster_command;
REVOKE ALL ON FUNCTION public.procurement_person_roster_command(uuid,text,uuid,integer,text,jsonb,jsonb)
 FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.procurement_command(
 p_store_id uuid,p_action text,p_record_id uuid,p_expected_version integer,
 p_idempotency_key text,p_payload jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor jsonb;kind text;subject uuid;principal public.users%rowtype;
 name text;v_stage text;payload jsonb;h text;actor_key text;
 prior public.procurement_command_results%rowtype;result jsonb;
BEGIN
 IF p_action<>'assign_principal' THEN
  RETURN public.procurement_person_roster_command(p_store_id,p_action,p_record_id,
   p_expected_version,p_idempotency_key,p_payload,p_office_actor);
 END IF;
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 IF auth.role() IS DISTINCT FROM 'service_role' OR actor->>'system'<>'office'
    OR NOT COALESCE((actor->>'can_manage')::boolean,false) THEN
  RAISE EXCEPTION 'PROCUREMENT_MANAGE_FORBIDDEN';
 END IF;
 kind:=COALESCE(p_payload->>'account_kind','person');
 IF kind NOT IN ('person','shared_role') THEN RAISE EXCEPTION 'PROCUREMENT_ACCOUNT_KIND_INVALID';END IF;
 subject:=(p_payload->>'subject_id')::uuid;v_stage:=p_payload->>'stage';
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text||':roster',0));
 IF EXISTS(SELECT 1 FROM public.procurement_role_roster WHERE restaurant_id=p_store_id
   AND system=p_payload->>'system' AND subject_id=subject AND account_kind<>kind) THEN
  RAISE EXCEPTION 'PROCUREMENT_PRINCIPAL_IDENTITY_CONFLICT';
 END IF;
 IF kind='person' THEN
  RETURN public.procurement_person_roster_command(p_store_id,p_action,p_record_id,
   p_expected_version,p_idempotency_key,p_payload,p_office_actor);
 END IF;
 IF p_payload->>'system'='pos' THEN
  SELECT * INTO principal FROM public.users WHERE auth_id=subject AND is_active;
  IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM public.user_accessible_stores(subject) s(store_id)
    WHERE s.store_id=p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_PRINCIPAL_REQUIRED';END IF;
  IF NOT COALESCE(CASE v_stage
   WHEN 'requester' THEN principal.role IN ('inventory_orderer','admin','store_admin','brand_admin','super_admin')
   WHEN 'receiver' THEN principal.role IN ('inventory_orderer','admin','store_admin','brand_admin','super_admin')
   WHEN 'store' THEN principal.role IN ('admin','store_admin','super_admin')
   WHEN 'brand' THEN principal.role IN ('brand_admin','super_admin')
   WHEN 'verifier' THEN principal.role IN ('inventory_accounting','super_admin')
   ELSE false END,false) THEN RAISE EXCEPTION 'PROCUREMENT_PRINCIPAL_STAGE_FORBIDDEN';END IF;
  name:=COALESCE(NULLIF(btrim(principal.full_name),''),subject::text);
 ELSIF p_payload->>'system'='office' THEN
  IF p_payload->'principal_confirmation'->>'subject_id' IS DISTINCT FROM subject::text
   OR p_payload->'principal_confirmation'->>'pos_store_id' IS DISTINCT FROM p_store_id::text
   OR p_payload->'principal_confirmation'->>'stage' IS DISTINCT FROM v_stage
   OR p_payload->'principal_confirmation'->>'can_assign_stage' IS DISTINCT FROM 'true' THEN
   RAISE EXCEPTION 'PROCUREMENT_PRINCIPAL_REQUIRED';
  END IF;
  name:=NULLIF(btrim(p_payload->'principal_confirmation'->>'display_name'),'');
  IF name IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_PRINCIPAL_REQUIRED';END IF;
 ELSE RAISE EXCEPTION 'PROCUREMENT_PRINCIPAL_REQUIRED';END IF;
 IF NULLIF(btrim(p_idempotency_key),'') IS NULL OR length(p_idempotency_key)>160 THEN
  RAISE EXCEPTION 'PROCUREMENT_IDEMPOTENCY_KEY_REQUIRED';END IF;
 -- Ignore client employee/name claims; only validated native account names are stored.
 payload:=(p_payload-'person_id'-'employee_confirmation'-'display_name')||jsonb_build_object('account_kind',kind);
 h:=encode(extensions.digest(convert_to(jsonb_build_object('action',p_action,'record',p_record_id,
  'version',p_expected_version,'payload',payload)::text,'UTF8'),'sha256'),'hex');
 actor_key:=(actor->>'system')||':'||(actor->>'subject_id');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text||':'||p_idempotency_key,0));
 SELECT * INTO prior FROM public.procurement_command_results WHERE restaurant_id=p_store_id AND idempotency_key=p_idempotency_key;
 IF FOUND THEN
  IF prior.actor_key<>actor_key OR prior.payload_hash<>h THEN RAISE EXCEPTION 'PROCUREMENT_RETRY_MISMATCH';END IF;
  RETURN prior.result;
 END IF;
 INSERT INTO public.procurement_role_roster(restaurant_id,system,subject_id,person_id,account_kind,
  stage,display_name,valid_from,valid_until,reason,assigned_by)
 VALUES(p_store_id,p_payload->>'system',subject,NULL,kind,v_stage,name,
  (p_payload->>'valid_from')::timestamptz,(p_payload->>'valid_until')::timestamptz,p_payload->>'reason',actor)
 ON CONFLICT(restaurant_id,system,subject_id,stage) DO UPDATE SET
  display_name=EXCLUDED.display_name,valid_from=EXCLUDED.valid_from,valid_until=EXCLUDED.valid_until,
  reason=EXCLUDED.reason,assigned_by=EXCLUDED.assigned_by,updated_at=now()
 RETURNING to_jsonb(procurement_role_roster) INTO result;
 INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,reason,next_state)
 VALUES(p_store_id,p_store_id,p_action,actor,p_payload->>'reason',result);
 INSERT INTO public.procurement_command_results VALUES(p_store_id,p_idempotency_key,actor_key,h,result,now());
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) TO authenticated,service_role;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.procurement_role_roster'::regclass
  AND conname='procurement_roster_identity_check') OR position('PROCUREMENT_PRINCIPAL_STAGE_FORBIDDEN'
  IN pg_get_functiondef('public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure))=0 THEN
  RAISE EXCEPTION 'PROCUREMENT_SHARED_ACCOUNT_CONTRACT_FAILED';END IF;
END $$;
COMMIT;
