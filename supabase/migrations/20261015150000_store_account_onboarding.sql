-- Server-owned store registration and resumable account provisioning.
BEGIN;
ALTER TABLE public.brands ADD COLUMN IF NOT EXISTS short_code text;
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname='brands_short_code_contract' AND conrelid='public.brands'::regclass) THEN
 ALTER TABLE public.brands ADD CONSTRAINT brands_short_code_contract CHECK(short_code IS NULL OR short_code ~ '^[A-Z][A-Z0-9]{1,5}$');
END IF; END $$;
CREATE UNIQUE INDEX IF NOT EXISTS brands_short_code_unique ON public.brands(upper(short_code)) WHERE short_code IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS restaurants_short_code_unique ON public.restaurants(upper(short_code)) WHERE short_code IS NOT NULL;

CREATE OR REPLACE FUNCTION public.admin_set_registration_abbreviation_v1(p_kind text,p_id uuid,p_code text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_code text:=upper(btrim(p_code)); v_old text;
BEGIN
 PERFORM public.require_brand_admin_v1();
 IF v_code IS NULL OR v_code !~ '^[A-Z][A-Z0-9]{1,5}$' THEN RAISE EXCEPTION 'ABBREVIATION_INVALID'; END IF;
 IF p_kind='brand' THEN
  SELECT short_code INTO v_old FROM brands WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BRAND_NOT_FOUND'; END IF;
  IF v_old IS NOT NULL AND v_old IS DISTINCT FROM v_code AND EXISTS(SELECT 1 FROM store_fixed_account_requirements q JOIN restaurants r ON r.id=q.store_id WHERE r.brand_id=p_id AND q.scope='brand') THEN
   RAISE EXCEPTION 'ABBREVIATION_ALREADY_IN_USE'; END IF;
  UPDATE brands SET short_code=v_code WHERE id=p_id;
 ELSIF p_kind='store' THEN
  SELECT short_code INTO v_old FROM restaurants WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'STORE_NOT_FOUND'; END IF;
  IF v_old IS NOT NULL AND v_old IS DISTINCT FROM v_code AND EXISTS(SELECT 1 FROM store_fixed_account_requirements WHERE store_id=p_id) THEN RAISE EXCEPTION 'ABBREVIATION_ALREADY_IN_USE'; END IF;
  UPDATE restaurants SET short_code=v_code WHERE id=p_id;
 ELSE RAISE EXCEPTION 'ABBREVIATION_KIND_INVALID'; END IF;
 IF v_old IS DISTINCT FROM v_code THEN INSERT INTO audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'registration_abbreviation_updated',CASE p_kind WHEN 'brand' THEN 'brands' ELSE 'restaurants' END,p_id,jsonb_build_object('previous',v_old,'short_code',v_code)); END IF;
 RETURN v_code;
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'ABBREVIATION_EXISTS';
END $$;


CREATE OR REPLACE FUNCTION public.admin_update_store_registration_v1(p_store_id uuid,p_name text,p_address text,p_code text,p_operation_mode text,p_per_person_charge numeric,p_tax_entity_id uuid,p_brand_id uuid)
RETURNS public.restaurants LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_old public.restaurants; v_result public.restaurants;
BEGIN
 PERFORM public.require_brand_admin_v1();
 SELECT * INTO v_old FROM restaurants WHERE id=p_store_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'STORE_NOT_FOUND'; END IF;
 IF (v_old.brand_id IS DISTINCT FROM p_brand_id OR v_old.tax_entity_id IS DISTINCT FROM p_tax_entity_id) AND EXISTS(SELECT 1 FROM store_account_onboarding_jobs WHERE store_id=p_store_id) THEN RAISE EXCEPTION 'ISSUED_ACCOUNT_SCOPE_LOCKED'; END IF;
 PERFORM public.admin_set_registration_abbreviation_v1('store',p_store_id,p_code);
 v_result:=public.admin_update_restaurant_v2(p_store_id,p_name,v_old.slug,p_operation_mode,p_tax_entity_id,p_brand_id,p_address,p_per_person_charge);
 RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.admin_update_store_registration_v1(uuid,text,text,text,text,numeric,uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_update_store_registration_v1(uuid,text,text,text,text,numeric,uuid,uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_create_brand_v2(p_brand_id uuid,p_name text,p_code text,p_brand_master_id uuid,p_tax_entity_ids uuid[] DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_result jsonb; v_code text;
BEGIN
 v_result:=public.admin_create_brand_v1(p_brand_id,p_name,lower(p_code),p_brand_master_id,p_tax_entity_ids);
 v_code:=public.admin_set_registration_abbreviation_v1('brand',p_brand_id,p_code);
 RETURN v_result||jsonb_build_object('short_code',v_code);
END $$;
CREATE OR REPLACE FUNCTION public.admin_update_brand_registration_v2(p_brand_id uuid,p_code text,p_tax_entity_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_code text; v_result jsonb;
BEGIN
 v_code:=public.admin_set_registration_abbreviation_v1('brand',p_brand_id,p_code);
 v_result:=public.admin_link_brand_tax_entities_v1(p_brand_id,p_tax_entity_ids);
 RETURN v_result||jsonb_build_object('short_code',v_code);
END $$;

CREATE TABLE IF NOT EXISTS public.store_account_onboarding_jobs(
 id uuid PRIMARY KEY, store_id uuid NOT NULL UNIQUE REFERENCES public.restaurants(id),
 actor_id uuid NOT NULL REFERENCES public.users(id), input jsonb NOT NULL, accounts jsonb NOT NULL CHECK(jsonb_typeof(accounts)='array' AND jsonb_array_length(accounts) BETWEEN 1 AND 50),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN('pending','running','partial','complete')),
 lease_id uuid,lease_until timestamptz, attempts integer NOT NULL DEFAULT 0,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.store_account_onboarding_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_account_onboarding_jobs FROM PUBLIC,anon,authenticated;
CREATE INDEX IF NOT EXISTS store_account_jobs_pending_idx ON public.store_account_onboarding_jobs(updated_at) WHERE status IN('pending','running');


CREATE OR REPLACE FUNCTION public.admin_preview_store_accounts_v1(p_brand_id uuid,p_code text,p_floors text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_brand_code text; v_result jsonb;
BEGIN
 PERFORM require_brand_admin_v1();
 IF p_code IS NULL OR upper(btrim(p_code)) !~ '^[A-Z][A-Z0-9]{1,5}$' THEN RAISE EXCEPTION 'ABBREVIATION_INVALID'; END IF;
 IF p_floors IS NULL OR cardinality(p_floors) NOT BETWEEN 1 AND 3 OR array_position(p_floors,NULL) IS NOT NULL OR NOT p_floors <@ ARRAY['1F','2F','3F'] THEN RAISE EXCEPTION 'FLOORS_INVALID'; END IF;
 SELECT short_code INTO v_brand_code FROM brands WHERE id=p_brand_id;
 IF v_brand_code IS NULL THEN RAISE EXCEPTION 'BRAND_ABBREVIATION_REQUIRED'; END IF;
 WITH managers AS MATERIALIZED(SELECT DISTINCT ON(q.account_code) q.account_code,q.account_type,q.role,q.display_name,q.scope FROM store_fixed_account_requirements q JOIN restaurants r ON r.id=q.store_id WHERE r.brand_id=p_brand_id AND q.scope='brand' AND q.is_active ORDER BY q.account_code,q.created_at), templates AS(
 SELECT * FROM managers UNION ALL
 SELECT lower(v_brand_code)||'_bm1','brand_manager','brand_admin','Brand Manager','brand' WHERE NOT EXISTS(SELECT 1 FROM managers)
 UNION ALL SELECT lower(btrim(p_code))||'_'||suffix,account_type,role,label,'store' FROM (VALUES ('sm1','store_manager','store_admin','Store Manager'),('pos1','device_pos','cashier','Cashier'),('tab1','device_tablet','cashier','Tablet'),('kit','device_kitchen','kitchen','Kitchen'),('tray1','device_emergency_station','emergency_station','Tray'),('pr1','inventory_orderer','inventory_orderer','Requester'),('order','inventory_orderer','inventory_orderer','Receiver'),('print','device_print_station','print_station','Print Station'),('customer','device_customer_display','customer_display','Customer Display')) t(suffix,account_type,role,label)
 UNION ALL SELECT lower(btrim(p_code))||'_ops1','store_operator','photo_objet_store_operator','Store Operator','store' WHERE EXISTS(SELECT 1 FROM brands WHERE id=p_brand_id AND code='photo_objet')
 UNION ALL SELECT lower(btrim(p_code))||'_floor_'||lower(f),'device_emergency_station','emergency_station','Floor '||f,'store' FROM (SELECT DISTINCT unnest(p_floors) f) floors)
 SELECT jsonb_agg(to_jsonb(t) ORDER BY account_code) INTO v_result FROM templates t;
 IF jsonb_array_length(v_result)>50 THEN RAISE EXCEPTION 'ACCOUNT_LIMIT'; END IF;
 RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.admin_preview_store_accounts_v1(uuid,text,text[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_preview_store_accounts_v1(uuid,text,text[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_create_store_onboarding_v1(p_request_id uuid,p_name text,p_address text,p_code text,p_brand_id uuid,p_tax_entity_id uuid,p_floors text[],p_operation_mode text DEFAULT 'standard',p_per_person_charge numeric DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_input jsonb; v_job public.store_account_onboarding_jobs; v_store public.restaurants; v_brand_code text; v_code text:=upper(btrim(p_code)); v_floors text[]; v_accounts jsonb;
BEGIN
 PERFORM public.require_brand_admin_v1();
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'REQUEST_ID_REQUIRED'; END IF;
 SELECT array_agg(DISTINCT upper(btrim(f)) ORDER BY upper(btrim(f))) INTO v_floors FROM unnest(p_floors) f;
 IF cardinality(p_floors) NOT BETWEEN 1 AND 3 OR v_floors IS NULL OR NOT v_floors <@ ARRAY['1F','2F','3F'] THEN RAISE EXCEPTION 'FLOORS_INVALID'; END IF;
 IF v_code IS NULL OR v_code !~ '^[A-Z][A-Z0-9]{1,5}$' THEN RAISE EXCEPTION 'ABBREVIATION_INVALID'; END IF;
 IF p_operation_mode IS NULL OR (p_operation_mode IN('buffet','hybrid') AND coalesce(p_per_person_charge,0)<=0) OR p_operation_mode NOT IN('standard','buffet','hybrid') OR length(btrim(p_name)) NOT BETWEEN 1 AND 120 OR length(coalesce(p_address,''))>500 THEN RAISE EXCEPTION 'STORE_INPUT_INVALID'; END IF;
 v_input:=jsonb_build_object('name',btrim(p_name),'address',btrim(p_address),'code',v_code,'brand',p_brand_id,'entity',p_tax_entity_id,'floors',v_floors,'mode',p_operation_mode,'charge',p_per_person_charge);
 PERFORM pg_advisory_xact_lock(hashtextextended('store-onboarding:'||p_request_id,0));
 SELECT * INTO v_job FROM store_account_onboarding_jobs WHERE id=p_request_id;
 IF FOUND THEN
  IF v_job.input<>v_input OR v_job.actor_id<>(SELECT id FROM users WHERE auth_id=auth.uid()) THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN v_job.store_id;
 END IF;
 SELECT short_code INTO v_brand_code FROM brands WHERE id=p_brand_id FOR UPDATE;
 IF v_brand_code IS NULL THEN RAISE EXCEPTION 'BRAND_ABBREVIATION_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM restaurants WHERE upper(short_code)=v_code) THEN RAISE EXCEPTION 'ABBREVIATION_EXISTS'; END IF;
 v_accounts:=public.admin_preview_store_accounts_v1(p_brand_id,v_code,v_floors);
 v_store:=public.admin_create_restaurant_v2(p_name,'store-'||p_request_id,p_operation_mode,p_tax_entity_id,p_brand_id,p_address,p_per_person_charge);
 UPDATE restaurants SET short_code=v_code WHERE id=v_store.id;
 INSERT INTO store_account_onboarding_jobs(id,store_id,actor_id,input,accounts) SELECT p_request_id,v_store.id,id,v_input,v_accounts FROM users WHERE auth_id=auth.uid();
 INSERT INTO store_fixed_account_requirements(store_id,account_code,account_type,role,display_name,scope)
 SELECT v_store.id,t.account_code,t.account_type,t.role,p_name||' '||t.display_name,t.scope FROM jsonb_to_recordset(v_accounts) t(account_code text,account_type text,role text,display_name text,scope text);
 IF (SELECT count(*) FROM store_fixed_account_requirements WHERE store_id=v_store.id)>50 THEN RAISE EXCEPTION 'ACCOUNT_LIMIT'; END IF;
 INSERT INTO audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'admin_create_store_onboarding_v1','restaurants',v_store.id,jsonb_build_object('request_id',p_request_id,'short_code',v_code,'floors',v_floors));
 RETURN v_store.id;
END $$;

CREATE OR REPLACE FUNCTION public.admin_store_onboarding_status_v1(p_job_id uuid,p_retry boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_job public.store_account_onboarding_jobs; v_result jsonb;
BEGIN
 PERFORM public.require_brand_admin_v1();
 SELECT * INTO v_job FROM store_account_onboarding_jobs WHERE id=p_job_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'JOB_NOT_FOUND'; END IF;
 IF p_retry AND v_job.status='partial' THEN UPDATE store_account_onboarding_jobs SET status='pending',attempts=0,updated_at=now() WHERE id=p_job_id; END IF;
 SELECT jsonb_build_object('job_id',j.id,'store_id',j.store_id,'status',j.status,'procurement_readiness',(SELECT readiness||jsonb_build_object('office_connected',office_connected) FROM procurement_store_onboarding WHERE restaurant_id=j.store_id),'items',jsonb_agg(jsonb_build_object('account_code',q.account_code,'role',q.role,'display_name',q.display_name,'scope',q.scope,'ready',q.provisioned_user_id IS NOT NULL) ORDER BY q.account_code)) INTO v_result FROM store_account_onboarding_jobs j JOIN store_fixed_account_requirements q ON q.store_id=j.store_id AND q.is_active WHERE j.id=p_job_id GROUP BY j.id;
 RETURN v_result;
END $$;


CREATE OR REPLACE FUNCTION public.admin_store_onboarding_for_store_v1(p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_id uuid;
BEGIN
 PERFORM require_brand_admin_v1();
 SELECT id INTO v_id FROM store_account_onboarding_jobs WHERE store_id=p_store_id;
 IF v_id IS NULL THEN RETURN NULL; END IF;
 RETURN admin_store_onboarding_status_v1(v_id);
END $$;
REVOKE ALL ON FUNCTION public.admin_store_onboarding_for_store_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_store_onboarding_for_store_v1(uuid) TO authenticated;

-- Freeze master-approved identity/scope templates. Later workforce edits cannot
-- cause a background master job to create additional or elevated identities.
CREATE OR REPLACE FUNCTION public.store_onboarding_manifest_matches_v1(p_store_id uuid,p_accounts jsonb)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 WITH actual AS MATERIALIZED(SELECT account_code,account_type,role,scope FROM store_fixed_account_requirements WHERE store_id=p_store_id AND is_active),
 expected AS MATERIALIZED(SELECT * FROM jsonb_to_recordset(p_accounts) t(account_code text,account_type text,role text,scope text))
 SELECT NOT EXISTS(SELECT 1 FROM actual a FULL JOIN expected e USING(account_code) WHERE a.account_code IS NULL OR e.account_code IS NULL OR a.account_type IS DISTINCT FROM e.account_type OR a.role IS DISTINCT FROM e.role OR a.scope IS DISTINCT FROM e.scope);
$$;
REVOKE ALL ON FUNCTION public.store_onboarding_manifest_matches_v1(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;

-- Only the worker may lease jobs. One indexed, bounded batch preloads Auth and profiles.
CREATE OR REPLACE FUNCTION public.claim_store_onboarding_v1(p_job_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_job public.store_account_onboarding_jobs; v_items jsonb;
BEGIN
 UPDATE store_account_onboarding_jobs j SET status='partial',lease_id=NULL,lease_until=NULL,updated_at=now() WHERE status IN('pending','running') AND (lease_until IS NULL OR lease_until<now()) AND (attempts>=3 OR NOT EXISTS(SELECT 1 FROM restaurants r WHERE r.id=j.store_id AND r.is_active) OR NOT EXISTS(SELECT 1 FROM users actor WHERE actor.id=j.actor_id AND actor.is_active AND actor.role='super_admin')); 
 SELECT * INTO v_job FROM store_account_onboarding_jobs WHERE (p_job_id IS NULL OR id=p_job_id) AND status IN('pending','running') AND (lease_until IS NULL OR lease_until<now()) AND attempts<3 AND EXISTS(SELECT 1 FROM restaurants r WHERE r.id=store_id AND r.is_active) AND EXISTS(SELECT 1 FROM users actor WHERE actor.id=actor_id AND actor.is_active AND actor.role='super_admin') ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1;
 IF NOT FOUND THEN RETURN NULL; END IF;
 IF NOT public.store_onboarding_manifest_matches_v1(v_job.store_id,v_job.accounts) THEN
  UPDATE store_account_onboarding_jobs SET status='partial',lease_id=NULL,lease_until=NULL,updated_at=now() WHERE id=v_job.id;
  RETURN NULL;
 END IF;
 UPDATE store_account_onboarding_jobs SET status='running',lease_id=gen_random_uuid(),lease_until=now()+interval '120 seconds',attempts=attempts+1,updated_at=now() WHERE id=v_job.id RETURNING * INTO v_job;
 SELECT jsonb_agg(jsonb_build_object('account_code',q.account_code,'display_name',q.display_name,'role',q.role,'account_type',q.account_type,'scope',q.scope,'owner_id',CASE q.scope WHEN 'brand' THEN r.brand_id ELSE r.id END,'auth_exists',a.id IS NOT NULL) ORDER BY q.account_code) INTO v_items
 FROM store_fixed_account_requirements q JOIN restaurants r ON r.id=q.store_id
 LEFT JOIN auth.users a ON a.instance_id='00000000-0000-0000-0000-000000000000' AND a.email=q.account_code||'@globos.world' AND a.is_sso_user=false
 WHERE q.store_id=v_job.store_id AND q.is_active;
 RETURN jsonb_build_object('job_id',v_job.id,'lease_id',v_job.lease_id,'items',v_items);
END $$;

CREATE OR REPLACE FUNCTION public.finish_store_onboarding_v1(p_job_id uuid,p_lease_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE v_job public.store_account_onboarding_jobs; v_count integer; v_affected uuid[];
BEGIN
 -- Serialize against normal workforce edits and store closure during reconciliation.
 PERFORM 1 FROM restaurants r JOIN store_account_onboarding_jobs j ON j.store_id=r.id WHERE j.id=p_job_id FOR UPDATE OF r;
 PERFORM 1 FROM store_fixed_account_requirements q JOIN store_account_onboarding_jobs j ON j.store_id=q.store_id WHERE j.id=p_job_id FOR UPDATE OF q;
 SELECT * INTO v_job FROM store_account_onboarding_jobs WHERE id=p_job_id AND lease_id=p_lease_id AND lease_until>now() AND status='running' AND EXISTS(SELECT 1 FROM restaurants r WHERE r.id=store_id AND r.is_active) AND EXISTS(SELECT 1 FROM users actor WHERE actor.id=actor_id AND actor.is_active AND actor.role='super_admin') FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'JOB_LEASE_INVALID'; END IF;
 IF NOT public.store_onboarding_manifest_matches_v1(v_job.store_id,v_job.accounts) THEN RAISE EXCEPTION 'JOB_REQUIREMENTS_CHANGED'; END IF;
 -- No client-supplied user IDs or roles. Reconcile lost Auth responses by exact email
 -- and a server-only app_metadata ownership marker; existing profiles must match scope.
 WITH eligible AS MATERIALIZED (
 SELECT q.*,a.id auth_id,r.brand_id FROM store_fixed_account_requirements q JOIN restaurants r ON r.id=q.store_id
 JOIN auth.users a ON a.instance_id='00000000-0000-0000-0000-000000000000' AND a.email=q.account_code||'@globos.world' AND a.is_sso_user=false
 LEFT JOIN users u ON u.auth_id=a.id OR u.fixed_account_code=q.account_code
 WHERE q.store_id=v_job.store_id AND q.is_active AND r.is_active
 AND ((u.id IS NULL AND a.raw_app_meta_data->'store_onboarding'=jsonb_build_object('code',q.account_code,'role',q.role,'type',q.account_type,'scope',q.scope,'owner_id',CASE q.scope WHEN 'brand' THEN r.brand_id ELSE r.id END))
 OR (u.auth_id=a.id AND u.fixed_account_code=q.account_code AND u.role=q.role AND u.account_type=q.account_type AND u.is_active AND ((q.scope='brand' AND EXISTS(SELECT 1 FROM user_brand_access ba WHERE ba.user_id=u.id AND ba.brand_id=r.brand_id AND ba.is_active)) OR (q.scope='store' AND u.restaurant_id=r.id)))))
 INSERT INTO users(auth_id,restaurant_id,primary_store_id,brand_id,role,full_name,is_active,account_type,fixed_account_code)
 SELECT auth_id,store_id,store_id,brand_id,role,display_name,true,account_type,account_code FROM eligible
 ON CONFLICT(auth_id) DO NOTHING;
 -- All writes below are limited to validated active profiles, never reactivating an identity.
 WITH matched AS MATERIALIZED (
 SELECT u.id,q.scope,r.brand_id FROM store_fixed_account_requirements q JOIN restaurants r ON r.id=q.store_id JOIN users u ON u.fixed_account_code=q.account_code JOIN auth.users a ON a.id=u.auth_id AND a.email=q.account_code||'@globos.world'
 WHERE q.store_id=v_job.store_id AND q.is_active AND u.is_active AND u.role=q.role AND u.account_type=q.account_type AND ((q.scope='brand' AND (u.brand_id=r.brand_id OR EXISTS(SELECT 1 FROM user_brand_access ba WHERE ba.user_id=u.id AND ba.brand_id=r.brand_id AND ba.is_active))) OR (q.scope='store' AND u.restaurant_id=r.id)))
 INSERT INTO user_brand_access(user_id,brand_id,is_active,granted_by) SELECT id,brand_id,true,v_job.actor_id FROM matched WHERE scope='brand' ON CONFLICT(user_id,brand_id) DO NOTHING;
 WITH matched AS MATERIALIZED (
 SELECT u.id,q.scope,r.brand_id FROM store_fixed_account_requirements q JOIN restaurants r ON r.id=q.store_id JOIN users u ON u.fixed_account_code=q.account_code JOIN auth.users a ON a.id=u.auth_id AND a.email=q.account_code||'@globos.world'
 WHERE q.store_id=v_job.store_id AND q.is_active AND u.is_active AND u.role=q.role AND u.account_type=q.account_type AND ((q.scope='brand' AND EXISTS(SELECT 1 FROM user_brand_access ba WHERE ba.user_id=u.id AND ba.brand_id=r.brand_id AND ba.is_active)) OR (q.scope='store' AND u.restaurant_id=r.id)))
 INSERT INTO user_store_access(user_id,store_id,is_primary,is_active,source_type,granted_by)
 SELECT m.id,r.id,m.scope='store',true,'direct',v_job.actor_id FROM matched m JOIN restaurants r ON (m.scope='brand' AND r.brand_id=m.brand_id OR m.scope='store' AND r.id=v_job.store_id) AND r.is_active
 ON CONFLICT(user_id,store_id,source_type) DO NOTHING;
 UPDATE store_fixed_account_requirements q SET provisioned_user_id=u.id,updated_at=now() FROM users u JOIN user_store_access sa ON sa.user_id=u.id AND sa.store_id=v_job.store_id AND sa.is_active
 WHERE q.store_id=v_job.store_id AND q.is_active AND u.fixed_account_code=q.account_code AND u.is_active AND u.role=q.role AND u.account_type=q.account_type AND ((q.scope='store' AND u.restaurant_id=v_job.store_id) OR (q.scope='brand' AND EXISTS(SELECT 1 FROM restaurants r JOIN user_brand_access ba ON ba.brand_id=r.brand_id AND ba.user_id=u.id AND ba.is_active WHERE r.id=v_job.store_id))) AND q.provisioned_user_id IS DISTINCT FROM u.id;
 -- The requirements statement trigger connects policy-3 requester/SM/receiver and
 -- existing shared legal accounting / Office buyer. No duplicate buyer is created.
 SELECT array_agg(DISTINCT u.id) INTO v_affected FROM users u JOIN user_store_access sa ON sa.user_id=u.id WHERE sa.store_id=v_job.store_id AND sa.is_active AND u.is_active;
 WITH affected AS MATERIALIZED(SELECT * FROM users WHERE id=ANY(v_affected)),
 store_scope AS MATERIALIZED(
  SELECT sa.user_id,sa.store_id FROM user_store_access sa JOIN affected u ON u.id=sa.user_id JOIN restaurants r ON r.id=sa.store_id AND r.is_active WHERE sa.is_active
  UNION SELECT u.id,r.id FROM affected u JOIN restaurants r ON r.id=coalesce(u.primary_store_id,u.restaurant_id) AND r.is_active
  UNION SELECT u.id,r.id FROM affected u JOIN user_tax_entity_access ea ON ea.user_id=u.id AND ea.is_active JOIN restaurants r ON r.tax_entity_id=ea.tax_entity_id AND r.is_active),
 stores AS(SELECT user_id,jsonb_agg(store_id) ids FROM store_scope GROUP BY user_id),
 brand_scope AS(SELECT ba.user_id,ba.brand_id FROM user_brand_access ba JOIN affected u ON u.id=ba.user_id WHERE ba.is_active UNION SELECT id,brand_id FROM affected WHERE brand_id IS NOT NULL),
 brands AS(SELECT user_id,jsonb_agg(brand_id) ids FROM brand_scope GROUP BY user_id),
 entity_scope AS(SELECT ea.user_id,ea.tax_entity_id FROM user_tax_entity_access ea JOIN affected u ON u.id=ea.user_id WHERE ea.is_active UNION SELECT s.user_id,r.tax_entity_id FROM store_scope s JOIN restaurants r ON r.id=s.store_id WHERE r.tax_entity_id IS NOT NULL),
 entities AS(SELECT user_id,jsonb_agg(tax_entity_id) ids FROM entity_scope GROUP BY user_id)
 UPDATE auth.users a SET raw_app_meta_data=coalesce(a.raw_app_meta_data,'{}')||jsonb_build_object('role',u.role,'primary_store_id',coalesce(u.primary_store_id,u.restaurant_id),'accessible_store_ids',coalesce(s.ids,'[]'),'brand_ids',coalesce(b.ids,'[]'),'accessible_tax_entity_ids',coalesce(e.ids,'[]')) FROM affected u LEFT JOIN stores s ON s.user_id=u.id LEFT JOIN brands b ON b.user_id=u.id LEFT JOIN entities e ON e.user_id=u.id WHERE a.id=u.auth_id;
 SELECT count(*) INTO v_count FROM store_fixed_account_requirements WHERE store_id=v_job.store_id AND is_active AND provisioned_user_id IS NULL;
 UPDATE store_account_onboarding_jobs SET status=CASE WHEN v_count=0 THEN 'complete' WHEN attempts>=3 THEN 'partial' ELSE 'pending' END,lease_id=NULL,lease_until=NULL,updated_at=now() WHERE id=p_job_id;
 RETURN jsonb_build_object('job_id',p_job_id,'store_id',v_job.store_id,'remaining',v_count,'status',CASE WHEN v_count=0 THEN 'complete' WHEN v_job.attempts>=3 THEN 'partial' ELSE 'pending' END);
END $$;

REVOKE ALL ON FUNCTION public.claim_store_onboarding_v1(uuid),public.finish_store_onboarding_v1(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_store_onboarding_v1(uuid),public.finish_store_onboarding_v1(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.admin_set_registration_abbreviation_v1(text,uuid,text),public.admin_create_brand_v2(uuid,text,text,uuid,uuid[]),public.admin_update_brand_registration_v2(uuid,text,uuid[]),public.admin_create_store_onboarding_v1(uuid,text,text,text,uuid,uuid,text[],text,numeric),public.admin_store_onboarding_status_v1(uuid,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_set_registration_abbreviation_v1(text,uuid,text),public.admin_create_brand_v2(uuid,text,text,uuid,uuid[]),public.admin_update_brand_registration_v2(uuid,text,uuid[]),public.admin_create_store_onboarding_v1(uuid,text,text,text,uuid,uuid,text[],text,numeric),public.admin_store_onboarding_status_v1(uuid,boolean) TO authenticated;
CREATE OR REPLACE FUNCTION public.admin_list_brands_v1(
  p_search text DEFAULT '', p_after_name text DEFAULT NULL,
  p_after_id uuid DEFAULT NULL, p_limit integer DEFAULT 50
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth AS $$
DECLARE
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 50);
  v_result jsonb;
BEGIN
  PERFORM public.require_brand_admin_v1();
  IF length(COALESCE(p_search, '')) > 100 THEN RAISE EXCEPTION 'BRAND_SEARCH_TOO_LONG'; END IF;
  IF (p_after_name IS NULL) <> (p_after_id IS NULL) THEN
    RAISE EXCEPTION 'BRAND_CURSOR_INVALID';
  END IF;
  -- Aggregate each relationship separately, limited to the requested page.
  -- Joining both raw one-to-many relations would multiply counts and payloads.
  WITH candidates AS MATERIALIZED (
    SELECT b.id, b.name, b.code, b.short_code, b.brand_master_id
    FROM public.brands b
    WHERE (COALESCE(btrim(p_search), '') = ''
      OR strpos(lower(b.name), lower(btrim(p_search))) > 0
      OR strpos(lower(b.code), lower(btrim(p_search))) > 0)
      AND (p_after_id IS NULL OR (lower(b.name), b.id) > (lower(p_after_name), p_after_id))
    ORDER BY lower(b.name), b.id LIMIT v_limit + 1
  ), page AS MATERIALIZED (
    SELECT * FROM candidates ORDER BY lower(name), id LIMIT v_limit
  ), links AS (
    SELECT l.brand_id, array_agg(l.tax_entity_id ORDER BY l.tax_entity_id) ids,
      array_agg(t.name ORDER BY l.tax_entity_id) names
    FROM public.tax_entity_brands l JOIN page p ON p.id = l.brand_id
    JOIN public.tax_entity t ON t.id = l.tax_entity_id GROUP BY l.brand_id
  ), counts AS (
    SELECT r.brand_id, count(*) store_count
    FROM public.restaurants r JOIN page p ON p.id = r.brand_id GROUP BY r.brand_id
  )
  SELECT jsonb_build_object('items', COALESCE(jsonb_agg(
    to_jsonb(p) || jsonb_build_object(
      'tax_entity_ids', COALESCE(l.ids, '{}'::uuid[]),
      'tax_entity_names', COALESCE(l.names, '{}'::text[]),
      'store_count', COALESCE(c.store_count, 0)
    ) ORDER BY lower(p.name), p.id), '[]'::jsonb),
    'has_more', (SELECT count(*) > v_limit FROM candidates)) INTO v_result
  FROM page p LEFT JOIN links l ON l.brand_id = p.id
  LEFT JOIN counts c ON c.brand_id = p.id;
  RETURN v_result;
END;
$$;


DO $floors$
DECLARE c record; f record; d text;
BEGIN
 FOR c IN SELECT conrelid::regclass tbl,conname,pg_get_constraintdef(oid) def FROM pg_constraint WHERE contype='c' AND conrelid IN ('public.emergency_station_assignments'::regclass,'public.emergency_order_queue'::regclass,'public.kds_shadow_health'::regclass,'public.kds_change_log'::regclass,'public.emergency_tray_floor_batch_actions'::regclass) AND pg_get_constraintdef(oid) LIKE '%1F%' AND pg_get_constraintdef(oid) LIKE '%2F%' LOOP
  d:=replace(c.def,'''2F''::text','''2F''::text, ''3F''::text');
  IF c.def NOT LIKE '%3F%' THEN EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I, ADD CONSTRAINT %I %s',c.tbl,c.conname,c.conname,d); END IF;
 END LOOP;
 FOR f IN SELECT oid FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname LIKE 'kds_dispatch_tray_floor%' LOOP
  d:=pg_get_functiondef(f.oid);
  IF d LIKE '%''1F'', ''2F''%' THEN EXECUTE replace(d,'''1F'', ''2F''','''1F'', ''2F'', ''3F'''); END IF;
 END LOOP;
END $floors$;
CREATE OR REPLACE FUNCTION public.sync_emergency_station_assignment_for_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_station text;
  v_floor text;
BEGIN
  IF NEW.fixed_account_code IS NULL OR NEW.restaurant_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.fixed_account_code ~ '_(tray1|tray)$' THEN
    v_station := 'tray';
  ELSIF NEW.fixed_account_code ~ '_(floor_1f|1f)$' THEN
    v_station := 'floor';
    v_floor := '1F';
  ELSIF NEW.fixed_account_code ~ '_(floor_[23]f|[23]f)$' THEN
    v_station := 'floor';
    v_floor := upper(substring(NEW.fixed_account_code from '([23]f)$'));
  ELSIF NEW.fixed_account_code ~ '_(kit1|kit)$' THEN
    v_station := 'kitchen';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO public.emergency_station_assignments (
    restaurant_id, user_id, station_type, floor_label, is_active
  ) VALUES (
    NEW.restaurant_id, NEW.id, v_station, v_floor, NEW.is_active
  )
  ON CONFLICT (restaurant_id, user_id) DO UPDATE SET
    station_type = EXCLUDED.station_type,
    floor_label = EXCLUDED.floor_label,
    is_active = EXCLUDED.is_active,
    updated_at = now();

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_emergency_station_assignment_for_user()
  FROM PUBLIC, anon, authenticated;


-- Durable retry after a browser disconnect or Edge process interruption. No secret
-- is stored in source; only an existing Vault secret is used by pg_net.
DO $schedule$
BEGIN
 IF EXISTS(SELECT 1 FROM cron.job WHERE jobname='store-account-onboarding') THEN PERFORM cron.unschedule('store-account-onboarding'); END IF;
 PERFORM cron.schedule('store-account-onboarding','* * * * *',$job$
 SELECT net.http_post(url:='https://ynriuoomotxuwhuxxmhj.supabase.co/functions/v1/store-account-onboarding',headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||(SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name IN('cron_secret','app.settings.cron_secret') ORDER BY (name='cron_secret') DESC LIMIT 1)),body:='{}'::jsonb)
 WHERE EXISTS(SELECT 1 FROM public.store_account_onboarding_jobs WHERE status IN('pending','running') AND (attempts<3 OR status='running') AND (lease_until IS NULL OR lease_until<now()));
 $job$);
END $schedule$;
-- Atomic structural verification before commit.
DO $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.restaurants'::regclass AND relkind='r') THEN RAISE EXCEPTION 'OFFICE_PHYSICAL_STORE_CONTRACT_CHANGED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.store_account_onboarding_jobs'::regclass AND relrowsecurity) THEN RAISE EXCEPTION 'ONBOARDING_RLS_MISSING'; END IF;
 IF has_function_privilege('authenticated','public.claim_store_onboarding_v1(uuid)','EXECUTE') OR has_function_privilege('anon','public.admin_create_store_onboarding_v1(uuid,text,text,text,uuid,uuid,text[],text,numeric)','EXECUTE') THEN RAISE EXCEPTION 'ONBOARDING_WORKER_EXPOSED'; END IF;
 IF NOT has_function_privilege('service_role','public.finish_store_onboarding_v1(uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION 'ONBOARDING_WORKER_INACCESSIBLE'; END IF;
 IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobname='store-account-onboarding' AND active) THEN RAISE EXCEPTION 'ONBOARDING_DURABLE_RETRY_MISSING'; END IF;
 IF EXISTS(SELECT 1 FROM pg_constraint WHERE contype='c' AND conrelid IN ('public.emergency_station_assignments'::regclass,'public.emergency_order_queue'::regclass,'public.kds_shadow_health'::regclass,'public.kds_change_log'::regclass,'public.emergency_tray_floor_batch_actions'::regclass) AND pg_get_constraintdef(oid) LIKE '%1F%' AND pg_get_constraintdef(oid) LIKE '%2F%' AND pg_get_constraintdef(oid) NOT LIKE '%3F%') THEN RAISE EXCEPTION 'THIRD_FLOOR_CONSTRAINT_MISSING'; END IF;
END $$;

COMMIT;
