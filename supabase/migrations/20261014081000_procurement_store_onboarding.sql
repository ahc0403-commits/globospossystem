-- Actual provisioned identities only. Auth, POS and Office form a resumable saga.
-- production-gate: self-verifying
BEGIN;
CREATE TABLE public.procurement_store_onboarding(
 restaurant_id uuid PRIMARY KEY REFERENCES public.restaurants(id),
 office_connected boolean NOT NULL DEFAULT false,
 readiness jsonb NOT NULL DEFAULT '{}',updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.procurement_store_onboarding ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_store_onboarding FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.procurement_store_onboarding TO service_role;

CREATE FUNCTION public.connect_procurement_stores(p_store_ids uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
 IF cardinality(p_store_ids)>100 THEN RAISE EXCEPTION 'PROCUREMENT_BATCH_LIMIT'; END IF;
 -- The requirement points to public.users.id, while the roster uses real Auth IDs.
 INSERT INTO public.procurement_role_roster(restaurant_id,system,subject_id,person_id,stage,display_name,valid_from,valid_until,reason,assigned_by,account_kind)
 SELECT DISTINCT q.store_id,'pos',u.auth_id,NULL::uuid,stage,COALESCE(NULLIF(u.full_name,''),q.display_name),now(),'infinity'::timestamptz,'Fixed account provisioning',
  jsonb_build_object('system','provisioning','subject_id',auth.uid(),'database_role',current_user),'shared_role'
 FROM public.store_fixed_account_requirements q JOIN public.users u ON u.id=q.provisioned_user_id AND u.is_active
 JOIN auth.users au ON au.id=u.auth_id
 JOIN (SELECT DISTINCT user_id,store_id FROM public.user_store_access WHERE is_active) a ON a.user_id=u.id AND a.store_id=q.store_id
 CROSS JOIN LATERAL(SELECT CASE WHEN q.role='store_admin' THEN 'store'
   WHEN q.role='inventory_orderer' AND q.account_code LIKE '%\_pr1' ESCAPE '\' THEN 'requester'
   WHEN q.role='inventory_orderer' AND q.account_code LIKE '%\_order' ESCAPE '\' THEN 'receiver' END stage) x
 WHERE q.store_id=ANY(p_store_ids) AND q.is_active AND q.scope='store' AND q.role=u.role AND q.account_code=u.fixed_account_code
 AND stage IS NOT NULL
 ON CONFLICT DO NOTHING;
 -- Accounting is an existing legal-entity identity, never a new account per store.
 INSERT INTO public.user_store_access(user_id,store_id,source_type)
 SELECT DISTINCT u.id,r.id,'direct' FROM public.restaurants r
 JOIN public.legal_entity_fixed_account_requirements q ON q.tax_entity_id=r.tax_entity_id AND q.is_active AND q.role='inventory_accounting'
 JOIN public.users u ON u.id=q.provisioned_user_id AND u.is_active AND u.role=q.role JOIN auth.users au ON au.id=u.auth_id
 WHERE r.id=ANY(p_store_ids) ON CONFLICT(user_id,store_id,source_type) DO NOTHING;
 INSERT INTO public.procurement_store_onboarding(restaurant_id,office_connected)
 SELECT DISTINCT q.store_id,rr.restaurant_id IS NOT NULL FROM public.store_fixed_account_requirements q
 LEFT JOIN(SELECT DISTINCT restaurant_id FROM public.procurement_role_roster WHERE system='office' AND stage='purchase' AND valid_from<=now() AND valid_until>now()) rr ON rr.restaurant_id=q.store_id WHERE q.store_id=ANY(p_store_ids)
 AND q.is_active AND q.role IN ('store_admin','inventory_orderer') ON CONFLICT DO NOTHING;
 WITH accounting AS MATERIALIZED(SELECT DISTINCT a.store_id FROM public.user_store_access a JOIN public.users u ON u.id=a.user_id AND u.is_active AND u.role='inventory_accounting' WHERE a.is_active UNION SELECT restaurant_id FROM public.procurement_role_roster WHERE system='office' AND stage='finance' AND valid_from<=now() AND valid_until>now()),stages AS(SELECT o.restaurant_id,o.office_connected,
  COALESCE(bool_or(rr.stage='requester' AND u.is_active AND u.role='inventory_orderer'),false) requester,
  COALESCE(bool_or(rr.stage='store' AND u.is_active AND u.role='store_admin'),false) store_manager,
  COALESCE(bool_or(rr.stage='receiver' AND u.is_active AND u.role='inventory_orderer'),false) receiver,
  ac.store_id IS NOT NULL accounting
 FROM public.procurement_store_onboarding o LEFT JOIN accounting ac ON ac.store_id=o.restaurant_id LEFT JOIN public.procurement_role_roster rr ON rr.restaurant_id=o.restaurant_id
 AND rr.system='pos' AND rr.valid_from<=now() AND rr.valid_until>now() LEFT JOIN public.users u ON u.auth_id=rr.subject_id
 WHERE o.restaurant_id=ANY(p_store_ids) GROUP BY o.restaurant_id,o.office_connected,ac.store_id)
 UPDATE public.procurement_store_onboarding o SET readiness=to_jsonb(s)-'restaurant_id',updated_at=now() FROM stages s WHERE s.restaurant_id=o.restaurant_id;
 -- A pre-existing policy and all historical versions remain untouched.
 INSERT INTO public.procurement_store_policies(restaurant_id,enabled,two_stage_required,three_stage_required,new_requests_enabled)
 SELECT restaurant_id,true,true,false,true FROM public.procurement_store_onboarding
 WHERE restaurant_id=ANY(p_store_ids) AND office_connected AND readiness @> '{"requester":true,"store_manager":true,"receiver":true,"accounting":true}'
 ON CONFLICT DO NOTHING;
END $$;
REVOKE ALL ON FUNCTION public.connect_procurement_stores(uuid[]) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.procurement_requirements_connected()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE ids uuid[];
BEGIN
 SELECT array_agg(DISTINCT store_id) INTO ids FROM provisioned_rows;
 PERFORM public.connect_procurement_stores(chunk.ids) FROM(
  SELECT array_agg(id) ids FROM unnest(ids) WITH ORDINALITY u(id,n) GROUP BY (n-1)/100) chunk;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.procurement_requirements_connected() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER procurement_requirement_insert AFTER INSERT ON public.store_fixed_account_requirements
 REFERENCING NEW TABLE AS provisioned_rows FOR EACH STATEMENT EXECUTE FUNCTION public.procurement_requirements_connected();
CREATE TRIGGER procurement_requirement_update AFTER UPDATE ON public.store_fixed_account_requirements
 REFERENCING NEW TABLE AS provisioned_rows FOR EACH STATEMENT EXECUTE FUNCTION public.procurement_requirements_connected();

CREATE FUNCTION public.procurement_identity_readiness_changed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE ids uuid[];
BEGIN
 SELECT array_agg(DISTINCT store_id) INTO ids FROM(
  SELECT q.store_id FROM changed_identities u JOIN public.store_fixed_account_requirements q ON q.provisioned_user_id=u.id AND q.scope='store'
  UNION SELECT r.id FROM changed_identities u JOIN public.legal_entity_fixed_account_requirements q ON q.provisioned_user_id=u.id JOIN public.restaurants r ON r.tax_entity_id=q.tax_entity_id) affected;
 PERFORM public.connect_procurement_stores(chunk.ids) FROM(
  SELECT array_agg(id) ids FROM unnest(ids) WITH ORDINALITY u(id,n) GROUP BY (n-1)/100) chunk;
 RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.procurement_identity_readiness_changed() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER procurement_identity_readiness_update AFTER UPDATE ON public.users
 REFERENCING NEW TABLE AS changed_identities FOR EACH STATEMENT EXECUTE FUNCTION public.procurement_identity_readiness_changed();

CREATE FUNCTION public.procurement_onboarding_page(p_after uuid DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'PROCUREMENT_MANAGE_FORBIDDEN'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY id) FROM(
  SELECT r.id,r.name,r.brand_id,r.tax_entity_id,o.readiness FROM public.procurement_store_onboarding o JOIN public.restaurants r ON r.id=o.restaurant_id
  WHERE r.is_active AND (p_after IS NULL OR r.id>p_after) ORDER BY r.id LIMIT greatest(1,least(100,p_limit))) x),'[]');
END $$;
CREATE FUNCTION public.procurement_complete_office_onboarding(p_stores jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE ids uuid[];
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'PROCUREMENT_MANAGE_FORBIDDEN'; END IF;
 IF jsonb_typeof(p_stores) IS DISTINCT FROM 'array' OR jsonb_array_length(p_stores)>100 THEN RAISE EXCEPTION 'PROCUREMENT_BATCH_LIMIT'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_stores) AS s(id uuid,brand_id uuid,tax_entity_id uuid,office_store_id uuid,principals jsonb)
 LEFT JOIN public.restaurants r ON r.id=s.id AND r.brand_id=s.brand_id AND r.tax_entity_id=s.tax_entity_id
 WHERE r.id IS NULL OR s.office_store_id IS NULL OR jsonb_typeof(s.principals) IS DISTINCT FROM 'array' OR jsonb_array_length(s.principals)>100)
 THEN RAISE EXCEPTION 'PROCUREMENT_STORE_SCOPE_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_stores) s CROSS JOIN LATERAL jsonb_array_elements(s->'principals') p
 WHERE p->>'system' IS DISTINCT FROM 'office' OR p->>'stage' NOT IN ('purchase','finance') OR NULLIF(p->>'subject_id','') IS NULL
 OR NULLIF(p->>'display_name','') IS NULL OR p->>'native_scope_confirmed' IS DISTINCT FROM 'true')
 THEN RAISE EXCEPTION 'PROCUREMENT_PRINCIPAL_REQUIRED'; END IF;
 INSERT INTO public.procurement_role_roster(restaurant_id,system,subject_id,person_id,stage,display_name,valid_from,valid_until,reason,assigned_by,account_kind)
 SELECT DISTINCT (s->>'id')::uuid,'office',(p->>'subject_id')::uuid,NULL::uuid,p->>'stage',p->>'display_name',now(),COALESCE(NULLIF(p->>'valid_until','')::timestamptz,'infinity'::timestamptz),
  'Native Office scope connected',jsonb_build_object('system','office_scope_sync','office_store_id',s->>'office_store_id','grant_ids',p->'grant_ids'),'shared_role'
 FROM jsonb_array_elements(p_stores) s CROSS JOIN LATERAL jsonb_array_elements(s->'principals') p ON CONFLICT(restaurant_id,system,subject_id,stage) DO UPDATE SET
  valid_from=CASE WHEN procurement_role_roster.valid_until<=now() THEN EXCLUDED.valid_from ELSE procurement_role_roster.valid_from END,
  valid_until=EXCLUDED.valid_until,display_name=EXCLUDED.display_name,assigned_by=EXCLUDED.assigned_by,reason=EXCLUDED.reason,updated_at=now()
 WHERE procurement_role_roster.assigned_by->>'system'='office_scope_sync' AND
  (procurement_role_roster.valid_until IS DISTINCT FROM EXCLUDED.valid_until OR procurement_role_roster.display_name IS DISTINCT FROM EXCLUDED.display_name
   OR procurement_role_roster.assigned_by IS DISTINCT FROM EXCLUDED.assigned_by);
 WITH incoming AS MATERIALIZED(SELECT (s->>'id')::uuid store_id,s->'principals' principals FROM jsonb_array_elements(p_stores) s),
 principals AS MATERIALIZED(SELECT i.store_id,(p->>'subject_id')::uuid subject_id,p->>'stage' stage FROM incoming i CROSS JOIN LATERAL jsonb_array_elements(i.principals) p),
 stale AS(SELECT rr.restaurant_id,rr.subject_id,rr.stage FROM public.procurement_role_roster rr JOIN incoming i ON i.store_id=rr.restaurant_id
 LEFT JOIN principals p ON p.store_id=rr.restaurant_id AND p.subject_id=rr.subject_id AND p.stage=rr.stage
 WHERE rr.system='office' AND rr.assigned_by->>'system'='office_scope_sync' AND rr.valid_until>now() AND p.subject_id IS NULL)
 UPDATE public.procurement_role_roster rr SET valid_until=clock_timestamp(),reason='Native Office scope no longer active; detected by sync',updated_at=clock_timestamp()
 FROM stale s WHERE rr.restaurant_id=s.restaurant_id AND rr.subject_id=s.subject_id AND rr.stage=s.stage AND rr.system='office';
 SELECT array_agg((s->>'id')::uuid) INTO ids FROM jsonb_array_elements(p_stores) s;
 INSERT INTO public.procurement_store_onboarding(restaurant_id,office_connected)
 SELECT (s->>'id')::uuid,EXISTS(SELECT 1 FROM jsonb_array_elements(s->'principals') p WHERE p->>'stage'='purchase') FROM jsonb_array_elements(p_stores) s
 ON CONFLICT(restaurant_id) DO UPDATE SET office_connected=EXCLUDED.office_connected,updated_at=now();
 PERFORM public.connect_procurement_stores(ids);
 RETURN jsonb_build_object('connected',COALESCE(cardinality(ids),0));
END $$;
REVOKE ALL ON FUNCTION public.procurement_onboarding_page(uuid,integer),public.procurement_complete_office_onboarding(jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.procurement_onboarding_page(uuid,integer),public.procurement_complete_office_onboarding(jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.admin_configure_store_workforce(
  p_store_id uuid,
  p_short_code text,
  p_management_model text,
  p_brand_manager_slots integer,
  p_account_templates jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_brand_id uuid;
  v_existing_short_code text;
  v_count integer := 0;
BEGIN
  v_actor := public.require_workforce_manager(p_store_id);
  SELECT brand_id, short_code INTO v_brand_id, v_existing_short_code
  FROM public.restaurants WHERE id = p_store_id;
  IF v_brand_id IS NULL THEN RAISE EXCEPTION 'STORE_BRAND_REQUIRED'; END IF;
  IF upper(btrim(p_short_code)) !~ '^[A-Z0-9]{2,6}$' THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_INVALID';
  END IF;
  IF p_management_model NOT IN ('brand_centralized', 'store_managed') THEN
    RAISE EXCEPTION 'MANAGEMENT_MODEL_INVALID';
  END IF;
  IF p_brand_manager_slots NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'BRAND_MANAGER_SLOTS_INVALID';
  END IF;
  IF jsonb_typeof(p_account_templates) <> 'array'
     OR jsonb_array_length(p_account_templates) = 0 THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATES_REQUIRED';
  END IF;
  IF jsonb_array_length(p_account_templates) > 50 THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATE_LIMIT';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_account_templates) item(value)
    GROUP BY lower(value->>'account_code') HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATE_DUPLICATE_CODE';
  END IF;
  IF (
    SELECT count(*) FROM jsonb_array_elements(p_account_templates) item(value)
    WHERE value->>'account_type' = 'brand_manager'
  ) NOT IN (0, p_brand_manager_slots) THEN
    RAISE EXCEPTION 'BRAND_MANAGER_TEMPLATE_COUNT_INVALID';
  END IF;
  IF v_existing_short_code IS NOT NULL
     AND v_existing_short_code <> upper(btrim(p_short_code))
     AND (
       EXISTS (SELECT 1 FROM public.store_employees WHERE store_id = p_store_id)
       OR EXISTS (
         SELECT 1 FROM public.store_fixed_account_requirements
         WHERE store_id = p_store_id AND provisioned_user_id IS NOT NULL
       )
     ) THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_IMMUTABLE_AFTER_USE';
  END IF;

  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_account_templates) x JOIN public.store_fixed_account_requirements q
    ON q.store_id=p_store_id AND q.account_code=x->>'account_code' AND q.provisioned_user_id IS NOT NULL
    WHERE q.role IS DISTINCT FROM x->>'role' OR q.account_type IS DISTINCT FROM x->>'account_type' OR q.scope IS DISTINCT FROM x->>'scope') THEN
    RAISE EXCEPTION 'PROVISIONED_ACCOUNT_TEMPLATE_IMMUTABLE'; END IF;
  UPDATE public.restaurants SET short_code = upper(btrim(p_short_code))
  WHERE id = p_store_id;
  UPDATE public.brands SET
    management_model = p_management_model,
    brand_manager_slots = p_brand_manager_slots
  WHERE id = v_brand_id;

  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_account_templates) x LEFT JOIN (VALUES
    ('brand_manager','brand_admin','brand'),('brand_manager','photo_objet_master','brand'),
    ('store_manager','store_admin','store'),('inventory_orderer','inventory_orderer','store'),
    ('device_pos','cashier','store'),('device_tablet','cashier','store'),('device_kitchen','kitchen','store'),
    ('device_print_station','print_station','store'),('device_customer_display','customer_display','store'),
    ('device_emergency_station','emergency_station','store'),('store_operator','photo_objet_store_operator','store')
  ) allowed(account_type,role,scope) ON allowed.account_type=x->>'account_type' AND allowed.role=x->>'role' AND allowed.scope=x->>'scope'
  WHERE allowed.account_type IS NULL) THEN RAISE EXCEPTION 'ACCOUNT_TEMPLATE_ROLE_SCOPE_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_account_templates) v_item WHERE COALESCE(v_item->>'account_code', '') !~ '^[a-z][a-z0-9_]{1,31}$'
       OR COALESCE(v_item->>'scope', '') NOT IN ('brand', 'store')
       OR COALESCE(v_item->>'account_type', '') NOT IN (
         'brand_manager', 'store_manager', 'inventory_orderer',
         'device_pos', 'device_tablet', 'device_kitchen', 'device_print_station',
         'device_customer_display', 'device_emergency_station', 'store_operator'
       )
       OR COALESCE(v_item->>'role', '') NOT IN (
         'brand_admin', 'store_admin', 'inventory_orderer',
         'cashier', 'kitchen', 'print_station', 'customer_display', 'emergency_station',
         'photo_objet_master', 'photo_objet_store_operator'
       )
       OR NULLIF(btrim(COALESCE(v_item->>'display_name', '')), '') IS NULL) THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATE_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_account_templates) v_item WHERE (v_item->>'account_type') = 'brand_manager'
       AND v_actor.role <> 'super_admin') THEN
    RAISE EXCEPTION 'BRAND_MANAGER_TEMPLATE_FORBIDDEN';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_account_templates) v_item WHERE (v_item->>'account_type') = 'store_manager'
       AND v_actor.role NOT IN ('super_admin', 'brand_admin')) THEN
    RAISE EXCEPTION 'STORE_MANAGER_TEMPLATE_FORBIDDEN';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_account_templates) v_item WHERE p_management_model = 'brand_centralized'
       AND (v_item->>'account_type') = 'store_manager') THEN
    RAISE EXCEPTION 'CENTRALIZED_STORE_MANAGER_FORBIDDEN';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_account_templates) v_item WHERE (v_item->>'account_type') IN (
      'inventory_orderer', 'device_pos', 'device_tablet', 'device_kitchen',
      'device_print_station', 'device_customer_display',
      'device_emergency_station', 'store_operator'
    ) AND (v_item->>'account_code') NOT LIKE
      lower(upper(btrim(p_short_code))) || '\_%' ESCAPE '\') THEN
    RAISE EXCEPTION 'STORE_ACCOUNT_CODE_PREFIX_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_account_templates) x JOIN public.store_fixed_account_requirements q
    ON q.account_code=x->>'account_code' AND q.store_id<>p_store_id AND q.is_active WHERE x->>'scope'='store') THEN
    RAISE EXCEPTION 'STORE_ACCOUNT_CODE_ALREADY_ASSIGNED'; END IF;
  INSERT INTO public.store_fixed_account_requirements(store_id,account_code,account_type,role,display_name,scope)
  SELECT p_store_id,x->>'account_code',x->>'account_type',x->>'role',btrim(x->>'display_name'),x->>'scope' FROM jsonb_array_elements(p_account_templates) x
  ON CONFLICT(store_id,account_code) DO UPDATE SET account_type=EXCLUDED.account_type,role=EXCLUDED.role,
   display_name=EXCLUDED.display_name,scope=EXCLUDED.scope,is_active=true,updated_at=now();
  v_count:=jsonb_array_length(p_account_templates);
  UPDATE public.store_fixed_account_requirements q SET
    is_active = false,
    updated_at = now()
  WHERE q.store_id = p_store_id
    AND q.provisioned_user_id IS NULL
    AND q.is_active = true
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_account_templates) item(value)
      WHERE lower(value->>'account_code') = lower(q.account_code)
    );
  RETURN jsonb_build_object(
    'configured', true,
    'store_id', p_store_id,
    'short_code', upper(btrim(p_short_code)),
    'management_model', p_management_model,
    'template_count', v_count
  );
END;
$$;

ALTER FUNCTION public.admin_get_store_workforce_readiness(uuid) RENAME TO admin_pre_procurement_workforce_readiness;
REVOKE ALL ON FUNCTION public.admin_pre_procurement_workforce_readiness(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.admin_get_store_workforce_readiness(p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE result jsonb;ready jsonb;
BEGIN
 result:=public.admin_pre_procurement_workforce_readiness(p_store_id);
 SELECT readiness||jsonb_build_object('office_connected',office_connected) INTO ready FROM public.procurement_store_onboarding WHERE restaurant_id=p_store_id;
 RETURN result||jsonb_build_object('procurement_readiness',COALESCE(ready,'{}'));
END $$;
REVOKE ALL ON FUNCTION public.admin_get_store_workforce_readiness(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_get_store_workforce_readiness(uuid) TO authenticated;

DO $$ DECLARE ids uuid[]; BEGIN
 SELECT array_agg(DISTINCT store_id) INTO ids FROM public.store_fixed_account_requirements WHERE is_active AND role IN ('store_admin','inventory_orderer');
 PERFORM public.connect_procurement_stores(chunk.ids) FROM(SELECT array_agg(id) ids FROM unnest(ids) WITH ORDINALITY u(id,n) GROUP BY (n-1)/100) chunk;
 IF has_function_privilege('authenticated','public.procurement_complete_office_onboarding(jsonb)','EXECUTE')
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='procurement_requirement_update') THEN RAISE EXCEPTION 'PROCUREMENT_ONBOARDING_CONTRACT_INVALID'; END IF;
END $$;
COMMIT;
