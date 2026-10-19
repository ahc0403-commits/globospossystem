BEGIN;
CREATE TABLE public.procurement_role_roster(
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),system text NOT NULL CHECK(system IN ('pos','office')),
 subject_id uuid NOT NULL,person_id uuid NOT NULL,stage text NOT NULL CHECK(stage IN ('requester','store','brand','purchase','receiver','verifier','finance')),
 display_name text NOT NULL,valid_from timestamptz NOT NULL,valid_until timestamptz NOT NULL,reason text NOT NULL,
 assigned_by jsonb NOT NULL,updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(restaurant_id,system,subject_id,stage),CHECK(valid_until>valid_from AND length(btrim(reason))>0)
);
ALTER TABLE public.procurement_role_roster ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_role_roster FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.procurement_role_roster TO service_role;
CREATE FUNCTION public.procurement_same_person(p_left jsonb,p_right jsonb,p_store_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT COALESCE((p_left->>'system'=p_right->>'system' AND p_left->>'subject_id'=p_right->>'subject_id')
 OR COALESCE(NULLIF(p_left->>'person_id','')::uuid,(SELECT person_id FROM public.procurement_role_roster WHERE restaurant_id=p_store_id AND system=p_left->>'system' AND subject_id::text=p_left->>'subject_id' LIMIT 1))
 =COALESCE(NULLIF(p_right->>'person_id','')::uuid,(SELECT person_id FROM public.procurement_role_roster WHERE restaurant_id=p_store_id AND system=p_right->>'system' AND subject_id::text=p_right->>'subject_id' LIMIT 1)),false)
$$;
REVOKE ALL ON FUNCTION public.procurement_same_person(jsonb,jsonb,uuid) FROM PUBLIC,anon,authenticated;
ALTER FUNCTION public.procurement_actor(uuid,jsonb) RENAME TO procurement_actor_base;
REVOKE ALL ON FUNCTION public.procurement_actor_base(uuid,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.procurement_actor(p_store_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor jsonb;person uuid;
BEGIN
 actor:=public.procurement_actor_base(p_store_id,p_office_actor)-'person_id';
 SELECT person_id INTO person FROM public.procurement_role_roster WHERE restaurant_id=p_store_id AND system=actor->>'system' AND subject_id::text=actor->>'subject_id' LIMIT 1;
 RETURN actor||jsonb_build_object('person_id',person);
END $$;
REVOKE ALL ON FUNCTION public.procurement_actor(uuid,jsonb) FROM PUBLIC,anon,authenticated;
ALTER FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) RENAME TO procurement_followup_command;
REVOKE ALL ON FUNCTION public.procurement_followup_command(uuid,text,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.procurement_command(p_store_id uuid,p_action text,p_record_id uuid,p_expected_version integer,p_idempotency_key text,p_payload jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE actor jsonb;req public.inventory_purchase_requests%rowtype;row public.procurement_role_roster%rowtype;prior public.procurement_command_results%rowtype;h text;result jsonb;actor_key text;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 IF p_action='assign_principal' THEN
  IF auth.role() IS DISTINCT FROM 'service_role' OR actor->>'system'<>'office' OR NOT COALESCE((actor->>'can_manage')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_MANAGE_FORBIDDEN'; END IF;
  IF p_payload->'employee_confirmation'->>'employee_id' IS DISTINCT FROM p_payload->>'person_id'
     OR p_payload->'employee_confirmation'->>'pos_store_id' IS DISTINCT FROM p_store_id::text THEN RAISE EXCEPTION 'PROCUREMENT_EMPLOYEE_MAPPING_REQUIRED'; END IF;
  IF p_payload->>'system'='pos' AND NOT EXISTS(SELECT 1 FROM public.users WHERE auth_id=(p_payload->>'subject_id')::uuid AND is_active) THEN RAISE EXCEPTION 'PROCUREMENT_PRINCIPAL_REQUIRED'; END IF;
  IF p_payload->>'system'='office' AND p_payload->'principal_confirmation'->>'subject_id' IS DISTINCT FROM p_payload->>'subject_id' THEN RAISE EXCEPTION 'PROCUREMENT_PRINCIPAL_REQUIRED'; END IF;
  IF NULLIF(btrim(p_idempotency_key),'') IS NULL OR length(p_idempotency_key)>160 THEN RAISE EXCEPTION 'PROCUREMENT_IDEMPOTENCY_KEY_REQUIRED'; END IF;
  h:=encode(extensions.digest(convert_to(jsonb_build_object('action',p_action,'record',p_record_id,'version',p_expected_version,'payload',p_payload)::text,'UTF8'),'sha256'),'hex');
  actor_key:=(actor->>'system')||':'||(actor->>'subject_id');
  PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text||':'||p_idempotency_key,0));
  SELECT * INTO prior FROM public.procurement_command_results WHERE restaurant_id=p_store_id AND idempotency_key=p_idempotency_key;
  IF FOUND THEN IF prior.actor_key<>actor_key OR prior.payload_hash<>h THEN RAISE EXCEPTION 'PROCUREMENT_RETRY_MISMATCH'; END IF;RETURN prior.result;END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text||':roster',0));
  IF EXISTS(SELECT 1 FROM public.procurement_role_roster WHERE restaurant_id=p_store_id AND system=p_payload->>'system' AND subject_id=(p_payload->>'subject_id')::uuid AND person_id<>(p_payload->>'person_id')::uuid) THEN RAISE EXCEPTION 'PROCUREMENT_PRINCIPAL_PERSON_CONFLICT'; END IF;
  INSERT INTO public.procurement_role_roster(restaurant_id,system,subject_id,person_id,stage,display_name,valid_from,valid_until,reason,assigned_by)
  VALUES(p_store_id,p_payload->>'system',(p_payload->>'subject_id')::uuid,(p_payload->>'person_id')::uuid,p_payload->>'stage',p_payload->'employee_confirmation'->>'name',(p_payload->>'valid_from')::timestamptz,(p_payload->>'valid_until')::timestamptz,p_payload->>'reason',actor)
  ON CONFLICT(restaurant_id,system,subject_id,stage) DO UPDATE SET valid_from=EXCLUDED.valid_from,valid_until=EXCLUDED.valid_until,reason=EXCLUDED.reason,assigned_by=EXCLUDED.assigned_by,updated_at=now() RETURNING to_jsonb(procurement_role_roster) INTO result;
  INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,reason,next_state) VALUES(p_store_id,p_store_id,p_action,actor,p_payload->>'reason',result);
  INSERT INTO public.procurement_command_results VALUES(p_store_id,p_idempotency_key,actor_key,h,result,now());
  RETURN result;
 END IF;
 IF p_action IN ('adjust_request','store_approve','brand_approve','office_approve','senior_approve') THEN
  SELECT * INTO req FROM public.inventory_purchase_requests WHERE id=p_record_id AND restaurant_id=p_store_id FOR UPDATE;
  IF req.approval_policy_version=2 THEN
   IF public.procurement_same_person(req.created_actor,actor,p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_SELF_APPROVAL_FORBIDDEN'; END IF;
   IF p_action IN ('brand_approve','office_approve','senior_approve') AND public.procurement_same_person(req.store_approved_actor,actor,p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_DISTINCT_APPROVER_REQUIRED'; END IF;
   IF p_action IN ('office_approve','senior_approve') AND public.procurement_same_person(req.brand_approved_actor,actor,p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_DISTINCT_APPROVER_REQUIRED'; END IF;
   IF p_action='senior_approve' AND public.procurement_same_person(req.office_approved_actor,actor,p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_DISTINCT_APPROVER_REQUIRED'; END IF;
  END IF;
 END IF;
 RETURN public.procurement_followup_command(p_store_id,p_action,p_record_id,p_expected_version,p_idempotency_key,p_payload,p_office_actor);
END $$;
REVOKE ALL ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) TO authenticated,service_role;
CREATE FUNCTION public.procurement_operating_metrics(p_store_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor jsonb;result jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 WITH requests AS MATERIALIZED(SELECT * FROM public.inventory_purchase_requests WHERE restaurant_id=p_store_id AND created_at>=now()-interval '90 days'),
 request_stats AS(SELECT count(*) total,count(*) FILTER(WHERE status='submitted') store_wait,count(*) FILTER(WHERE status='brand_review') brand_wait,count(*) FILTER(WHERE status IN ('office_review','senior_review')) purchase_wait,
  percentile_cont(0.95) WITHIN GROUP(ORDER BY extract(epoch FROM(now()-COALESCE(store_approved_at,submitted_at,created_at)))/3600) FILTER(WHERE status IN ('submitted','brand_review','office_review','senior_review')) waiting_p95_hours FROM requests),
 orders AS MATERIALIZED(SELECT * FROM public.inventory_purchase_orders WHERE restaurant_id=p_store_id AND workflow_version=2 AND created_at>=now()-interval '90 days'),
 exported AS(SELECT DISTINCT e.record_id FROM public.procurement_document_exports e JOIN orders po ON po.id=e.record_id WHERE e.kind='po' AND e.audience='supplier'),
 order_stats AS(SELECT count(*) total,count(*) FILTER(WHERE po.procurement_status IN ('sent','confirmed')) sent,count(*) FILTER(WHERE e.record_id IS NOT NULL) price_free_documents,
 count(*) FILTER(WHERE a.held_count>0 OR a.reconciliation_required) accounting_holds FROM orders po LEFT JOIN exported e ON e.record_id=po.id LEFT JOIN public.procurement_accounting_status a ON a.purchase_order_id=po.id),
 receipt_stats AS(SELECT count(*) FILTER(WHERE r.status='draft' AND r.submitted_at IS NOT NULL) inspection_wait FROM public.inventory_receipts r WHERE r.restaurant_id=p_store_id),
 issue_stats AS(SELECT count(*) FILTER(WHERE status='open') open_issues FROM public.inventory_receipt_issues WHERE restaurant_id=p_store_id)
 SELECT jsonb_build_object('as_of',now(),'window_days',90,'requests',to_jsonb(r),'orders',to_jsonb(o),'receipts',to_jsonb(c),'issues',to_jsonb(i)) INTO result FROM request_stats r CROSS JOIN order_stats o CROSS JOIN receipt_stats c CROSS JOIN issue_stats i;
 IF COALESCE((actor->>'can_manage')::boolean,false) THEN
  result:=result||jsonb_build_object('role_roster',COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM public.procurement_role_roster x WHERE restaurant_id=p_store_id),'[]'),
   'missing_stages',COALESCE((SELECT jsonb_agg(stage) FROM unnest(ARRAY['requester','store','brand','purchase','receiver','verifier','finance']) AS stages(stage) WHERE NOT EXISTS(SELECT 1 FROM public.procurement_role_roster x WHERE x.restaurant_id=p_store_id AND x.stage=stages.stage AND x.valid_from<=now() AND x.valid_until>now())),'[]'));
 END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_operating_metrics(uuid,jsonb) FROM PUBLIC,anon,authenticated;
ALTER FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) RENAME TO procurement_workspace_page_core;
REVOKE ALL ON FUNCTION public.procurement_workspace_page_core(uuid,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.procurement_workspace_page(p_store_id uuid,p_query jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
 result:=public.procurement_workspace_page_core(p_store_id,p_query,p_office_actor);
 IF COALESCE((p_query->>'include_metrics')::boolean,false) THEN result:=result||jsonb_build_object('operating_metrics',public.procurement_operating_metrics(p_store_id,p_office_actor)); END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) TO authenticated,service_role;
COMMIT;
