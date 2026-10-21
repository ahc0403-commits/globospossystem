-- Opening is an explicit transition, independent of account provisioning and buying.
-- Existing stores are grandfathered; new intake gates do not interrupt old orders.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.store_lifecycle (
 restaurant_id uuid PRIMARY KEY REFERENCES public.restaurants(id) ON DELETE CASCADE,
 state text NOT NULL CHECK(state IN('preparing','active','suspended','closed')),
 legacy_operational boolean NOT NULL DEFAULT false,
 revision bigint NOT NULL DEFAULT 0,
 activated_source_hash text,
 changed_by uuid, changed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.store_lifecycle(restaurant_id,state,legacy_operational)
SELECT r.id,CASE WHEN NOT r.is_active THEN 'closed' WHEN q.id IS NOT NULL THEN 'preparing' ELSE 'active' END,q.id IS NULL
FROM public.restaurants r LEFT JOIN public.store_registration_requests q ON q.store_id=r.id;
ALTER TABLE public.store_lifecycle ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_lifecycle FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.store_initialize_lifecycle_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 INSERT INTO public.store_lifecycle(restaurant_id,state) SELECT id,'preparing' FROM new_stores;
 RETURN NULL;
END $$;
CREATE TRIGGER store_initialize_lifecycle AFTER INSERT ON public.restaurants
 REFERENCING NEW TABLE AS new_stores FOR EACH STATEMENT EXECUTE FUNCTION public.store_initialize_lifecycle_v1();

CREATE TABLE public.store_credential_handovers (
 id uuid PRIMARY KEY,
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 employee_id uuid NOT NULL REFERENCES public.store_employees(id) DEFERRABLE INITIALLY DEFERRED,
 account_snapshot jsonb NOT NULL,
 evidence text NOT NULL CHECK(length(btrim(evidence)) BETWEEN 1 AND 500),
 actor_id uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX store_credential_handovers_store ON public.store_credential_handovers(restaurant_id,created_at DESC);
ALTER TABLE public.store_credential_handovers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_credential_handovers FROM PUBLIC,anon,authenticated;

CREATE TABLE public.store_opening_verifications (
 id uuid PRIMARY KEY,
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 source_hash text NOT NULL,
 evidence text NOT NULL CHECK(length(btrim(evidence)) BETWEEN 1 AND 500),
 actor_id uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX store_opening_verifications_source ON public.store_opening_verifications(restaurant_id,source_hash);
ALTER TABLE public.store_opening_verifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_opening_verifications FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.store_credential_snapshot_v1(p_store_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT coalesce(jsonb_agg(jsonb_build_object('requirement_id',q.id,'account_code',q.account_code,'user_id',u.id,
  'generation',u.password_change_generation,'ready',coalesce(u.is_active AND NOT u.must_change_password AND au.id IS NOT NULL
   AND EXISTS(SELECT 1 FROM user_store_access sa WHERE sa.user_id=u.id AND sa.store_id=p_store_id AND sa.is_active),false)) ORDER BY q.account_code),'[]')
 FROM store_fixed_account_requirements q LEFT JOIN users u ON u.id=q.provisioned_user_id AND u.fixed_account_code=q.account_code AND u.role=q.role AND u.account_type=q.account_type
 LEFT JOIN auth.users au ON au.id=u.auth_id
 WHERE q.store_id=p_store_id AND q.scope='store' AND q.is_active;
$$;

CREATE FUNCTION public.admin_record_store_handover_v1(p_request_id uuid,p_store_id uuid,p_employee_id uuid,p_evidence text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE snapshot jsonb; previous store_credential_handovers;
BEGIN
 PERFORM public.require_brand_admin_v1();
 IF p_request_id IS NULL OR length(btrim(coalesce(p_evidence,''))) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'HANDOVER_EVIDENCE_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||p_store_id,0));
 IF NOT EXISTS(SELECT 1 FROM store_employees WHERE id=p_employee_id AND store_id=p_store_id AND is_active) THEN RAISE EXCEPTION 'HANDOVER_EMPLOYEE_REQUIRED'; END IF;
 snapshot:=public.store_credential_snapshot_v1(p_store_id);
 IF jsonb_array_length(snapshot)=0 OR EXISTS(SELECT 1 FROM jsonb_array_elements(snapshot)a WHERE a->>'ready'<>'true') THEN RAISE EXCEPTION 'HANDOVER_ACCOUNTS_NOT_READY'; END IF;
 SELECT * INTO previous FROM store_credential_handovers WHERE id=p_request_id;
 IF FOUND THEN
  IF previous.restaurant_id<>p_store_id OR previous.employee_id<>p_employee_id OR previous.evidence<>btrim(p_evidence) OR previous.account_snapshot<>snapshot THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN previous.id;
 END IF;
 INSERT INTO store_credential_handovers(id,restaurant_id,employee_id,account_snapshot,evidence,actor_id)
 VALUES(p_request_id,p_store_id,p_employee_id,snapshot,btrim(p_evidence),auth.uid());
 RETURN p_request_id;
END $$;

CREATE FUNCTION public.admin_get_store_lifecycle_v1(p_store_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE state_row store_lifecycle; shop restaurants; cfg jsonb; accounts jsonb; opening jsonb; checks jsonb; v_source_hash text; registered boolean; result jsonb; v_at timestamptz:=clock_timestamp();
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 SELECT * INTO shop FROM restaurants WHERE id=p_store_id;
 SELECT * INTO state_row FROM store_lifecycle WHERE restaurant_id=p_store_id;
 IF shop.id IS NULL OR state_row.restaurant_id IS NULL THEN RAISE EXCEPTION 'STORE_NOT_FOUND'; END IF;
 SELECT input->'config' INTO cfg FROM store_account_onboarding_jobs WHERE store_id=p_store_id;
 registered:=cfg IS NOT NULL;
 accounts:=public.store_credential_snapshot_v1(p_store_id);
 opening:=public.admin_get_store_opening_readiness(p_store_id);
 checks:=jsonb_build_object(
  'identity',shop.short_code IS NOT NULL AND shop.brand_id IS NOT NULL AND shop.tax_entity_id IS NOT NULL AND EXISTS(SELECT 1 FROM tax_entity_brands WHERE tax_entity_id=shop.tax_entity_id AND brand_id=shop.brand_id),
  'accounts',jsonb_array_length(accounts)>0 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(accounts)a WHERE a->>'ready'<>'true'),
  'credential_handover',EXISTS(SELECT 1 FROM store_credential_handovers h JOIN store_employees e ON e.id=h.employee_id AND e.store_id=p_store_id AND e.is_active WHERE h.restaurant_id=p_store_id AND h.account_snapshot=accounts),
  'employees',EXISTS(SELECT 1 FROM store_employees WHERE store_id=p_store_id AND is_active),
  'opening_tests',coalesce((opening->>'ready')::boolean,false),
  'service_areas',NOT registered OR ((cfg->>'dine_in')::boolean=(EXISTS(SELECT 1 FROM tables WHERE restaurant_id=p_store_id))) AND NOT EXISTS(
    SELECT 1 FROM store_service_areas area WHERE area.restaurant_id=p_store_id AND NOT EXISTS(SELECT 1 FROM emergency_station_assignments a JOIN users u ON u.id=a.user_id AND u.is_active WHERE a.restaurant_id=p_store_id AND a.is_active AND a.station_type='floor' AND a.floor_label=area.stored_code)),
  'kitchens',EXISTS(SELECT 1 FROM emergency_station_assignments a JOIN users u ON u.id=a.user_id AND u.is_active WHERE a.restaurant_id=p_store_id AND a.is_active AND a.station_type='kitchen'),
  'workflow',coalesce((cfg->>'kitchens')::int,1)<=1 OR EXISTS(SELECT 1 FROM store_workflow_configs WHERE restaurant_id=p_store_id AND active_id IS NOT NULL),
  'menus',EXISTS(SELECT 1 FROM menu_items WHERE restaurant_id=p_store_id AND is_available AND NOT is_archived),
  'invoice_mapping',EXISTS(SELECT 1 FROM invoice_mapping_policies WHERE store_id=p_store_id AND tax_entity_id=shop.tax_entity_id AND effective_from<=v_at AND (effective_to IS NULL OR effective_to>v_at))
    AND NOT EXISTS(SELECT 1 FROM menu_items m WHERE m.restaurant_id=p_store_id AND m.is_available AND NOT m.is_archived AND NOT EXISTS(SELECT 1 FROM menu_invoice_profiles p WHERE p.menu_item_id=m.id AND p.tax_entity_id=shop.tax_entity_id AND p.effective_from<=v_at AND (p.effective_to IS NULL OR p.effective_to>v_at)))
 );
 -- Capture only bounded configuration data; sales and financial histories are not loaded.
 IF (SELECT count(*) FROM menu_items WHERE restaurant_id=p_store_id)>4000 THEN RAISE EXCEPTION 'WORKFLOW_MENU_LIMIT'; END IF;
 v_source_hash:=md5(jsonb_build_object('workflow',public.store_workflow_source(p_store_id),'accounts',accounts,'checks',checks,
  'printers',(SELECT jsonb_agg(jsonb_build_array(id,ip,port,purpose,floor_label,is_active,updated_at) ORDER BY id) FROM (SELECT * FROM printer_destinations WHERE restaurant_id=p_store_id ORDER BY id LIMIT 21)p),
  'printer_endpoints',(SELECT jsonb_agg(to_jsonb(ep) ORDER BY ep.id) FROM (SELECT e.* FROM printer_endpoints e WHERE e.physical_printer_id IN (SELECT physical_printer_id FROM printer_destinations WHERE restaurant_id=p_store_id) ORDER BY e.id LIMIT 101)ep))::text);
 checks:=checks||jsonb_build_object('field_verification',EXISTS(SELECT 1 FROM store_opening_verifications v WHERE v.restaurant_id=p_store_id AND v.source_hash=v_source_hash));
 result:=jsonb_build_object('can_manage',public.is_super_admin(),'lifecycle',to_jsonb(state_row),'checks',checks,'source_hash',v_source_hash,
  'business_ready',NOT EXISTS(SELECT 1 FROM jsonb_each(checks)c WHERE c.value<>'true'::jsonb),
  'procurement',coalesce((SELECT readiness||jsonb_build_object('office_connected',office_connected) FROM procurement_store_onboarding WHERE restaurant_id=p_store_id),'{}'),
  'accounts',accounts,'opening',opening,
  'employees',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'name',full_name) ORDER BY employee_number),'[]') FROM (SELECT id,full_name,employee_number FROM store_employees WHERE store_id=p_store_id AND is_active ORDER BY employee_number LIMIT 200)e));
 RETURN result;
END $$;

CREATE FUNCTION public.admin_record_store_verification_v1(p_request_id uuid,p_store_id uuid,p_source_hash text,p_evidence text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE readiness jsonb; previous store_opening_verifications;
BEGIN
 PERFORM public.require_brand_admin_v1();
 IF p_request_id IS NULL OR length(btrim(coalesce(p_evidence,''))) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'FIELD_VERIFICATION_EVIDENCE_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||p_store_id,0));
 readiness:=public.admin_get_store_lifecycle_v1(p_store_id);
 IF p_source_hash IS DISTINCT FROM readiness->>'source_hash' OR EXISTS(SELECT 1 FROM jsonb_each(readiness->'checks') c WHERE c.key<>'field_verification' AND c.value<>'true'::jsonb) THEN RAISE EXCEPTION 'STORE_OPENING_NOT_READY'; END IF;
 SELECT * INTO previous FROM store_opening_verifications WHERE id=p_request_id;
 IF FOUND THEN
  IF previous.restaurant_id<>p_store_id OR previous.source_hash<>p_source_hash OR previous.evidence<>btrim(p_evidence) THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN previous.id;
 END IF;
 INSERT INTO store_opening_verifications VALUES(p_request_id,p_store_id,p_source_hash,btrim(p_evidence),auth.uid(),now());
 RETURN p_request_id;
END $$;
REVOKE ALL ON FUNCTION public.admin_record_store_verification_v1(uuid,uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_record_store_verification_v1(uuid,uuid,text,text) TO authenticated;

CREATE FUNCTION public.admin_transition_store_lifecycle_v1(p_store_id uuid,p_expected_revision bigint,p_state text,p_source_hash text,p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE previous store_lifecycle; readiness jsonb;
BEGIN
 PERFORM public.require_brand_admin_v1();
 IF p_state NOT IN('active','suspended') OR length(btrim(coalesce(p_reason,''))) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'LIFECYCLE_TRANSITION_INVALID'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('store-opening:'||p_store_id,0));
 SELECT * INTO previous FROM store_lifecycle WHERE restaurant_id=p_store_id FOR UPDATE;
 IF NOT FOUND OR previous.revision<>p_expected_revision THEN RAISE EXCEPTION 'LIFECYCLE_CHANGED'; END IF;
 IF previous.state='closed' OR NOT EXISTS(SELECT 1 FROM restaurants WHERE id=p_store_id AND is_active) THEN RAISE EXCEPTION 'STORE_CLOSED'; END IF;
 IF p_state='suspended' AND EXISTS(SELECT 1 FROM direct_order_requests WHERE restaurant_id=p_store_id AND state IN('awaiting_quote','quoted','awaiting_payment_review')) THEN RAISE EXCEPTION 'STORE_PENDING_DIRECT_ORDERS'; END IF;
 readiness:=public.admin_get_store_lifecycle_v1(p_store_id);
 IF p_state='active' AND (p_source_hash IS DISTINCT FROM readiness->>'source_hash' OR NOT (readiness->>'business_ready')::boolean) THEN RAISE EXCEPTION 'STORE_OPENING_NOT_READY'; END IF;
 UPDATE store_lifecycle SET state=p_state,revision=revision+1,activated_source_hash=CASE WHEN p_state='active' THEN p_source_hash ELSE activated_source_hash END,changed_by=auth.uid(),changed_at=now() WHERE restaurant_id=p_store_id;
 INSERT INTO audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'store_lifecycle_transition','restaurants',p_store_id,jsonb_build_object('before',previous.state,'after',p_state,'reason',btrim(p_reason),'source_hash',p_source_hash));
 RETURN public.admin_get_store_lifecycle_v1(p_store_id);
END $$;

CREATE FUNCTION public.store_guard_new_intake_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 -- Same boundary as workflow activation. One check per affected store batch.
 PERFORM pg_advisory_xact_lock_shared(hashtextextended('store-opening:'||restaurant_id,0)) FROM (SELECT DISTINCT restaurant_id FROM new_intake ORDER BY restaurant_id)s;
 IF EXISTS(SELECT 1 FROM new_intake n JOIN store_lifecycle l ON l.restaurant_id=n.restaurant_id JOIN restaurants r ON r.id=n.restaurant_id WHERE l.state<>'active' OR NOT r.is_active) THEN RAISE EXCEPTION 'STORE_NOT_OPEN_FOR_NEW_ORDERS'; END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER store_lifecycle_orders AFTER INSERT ON public.orders REFERENCING NEW TABLE AS new_intake FOR EACH STATEMENT EXECUTE FUNCTION public.store_guard_new_intake_v1();
-- QR checkout creates orders through the same guarded order boundary.
CREATE TRIGGER store_lifecycle_direct AFTER INSERT ON public.direct_order_requests REFERENCING NEW TABLE AS new_intake FOR EACH STATEMENT EXECUTE FUNCTION public.store_guard_new_intake_v1();

CREATE FUNCTION public.store_guard_registered_identity_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF (NEW.brand_id,NEW.tax_entity_id,NEW.short_code) IS DISTINCT FROM (OLD.brand_id,OLD.tax_entity_id,OLD.short_code)
 AND EXISTS(SELECT 1 FROM store_account_onboarding_jobs WHERE store_id=OLD.id) THEN RAISE EXCEPTION 'STORE_REGISTERED_IDENTITY_FROZEN'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER store_registered_identity_guard BEFORE UPDATE OF brand_id,tax_entity_id,short_code ON public.restaurants FOR EACH ROW EXECUTE FUNCTION public.store_guard_registered_identity_v1();
REVOKE ALL ON FUNCTION public.store_initialize_lifecycle_v1(),public.store_credential_snapshot_v1(uuid),public.store_guard_new_intake_v1(),public.store_guard_registered_identity_v1() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.admin_record_store_handover_v1(uuid,uuid,uuid,text),public.admin_get_store_lifecycle_v1(uuid),public.admin_transition_store_lifecycle_v1(uuid,bigint,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_record_store_handover_v1(uuid,uuid,uuid,text),public.admin_get_store_lifecycle_v1(uuid),public.admin_transition_store_lifecycle_v1(uuid,bigint,text,text,text) TO authenticated;
COMMIT;
