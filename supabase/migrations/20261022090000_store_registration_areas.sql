-- Configuration-driven, restartable registration. Existing identities are immutable.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
ALTER TABLE public.store_service_areas ADD COLUMN display_name text,
 ADD COLUMN physical_floor text;
-- A NULL legacy display name reads as its existing code. Do not rewrite immutable areas.
ALTER TABLE public.store_service_areas ADD CONSTRAINT store_area_name_length CHECK(length(display_name) BETWEEN 1 AND 80),
 ADD CONSTRAINT store_area_physical_floor_length CHECK(physical_floor IS NULL OR length(physical_floor) BETWEEN 1 AND 40);

CREATE TABLE public.store_registration_requests (
 id uuid PRIMARY KEY,
 actor_id uuid NOT NULL REFERENCES public.users(id),
 code text NOT NULL UNIQUE CHECK(code ~ '^[A-Z][A-Z0-9]{1,5}$'),
 store_id uuid UNIQUE REFERENCES public.restaurants(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX store_registration_actor ON public.store_registration_requests(actor_id,created_at DESC);
ALTER TABLE public.store_registration_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_registration_requests FROM PUBLIC,anon,authenticated;
CREATE SEQUENCE public.store_registration_code_seq MAXVALUE 9999 NO CYCLE;
REVOKE ALL ON SEQUENCE public.store_registration_code_seq FROM PUBLIC,anon,authenticated;

CREATE TABLE public.store_registration_station_bindings (
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
 account_code text NOT NULL,
 station_id uuid NOT NULL,
 PRIMARY KEY(restaurant_id,account_code),
 FOREIGN KEY(restaurant_id,station_id) REFERENCES public.store_service_stations(restaurant_id,id) ON DELETE CASCADE
);
ALTER TABLE public.store_registration_station_bindings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_registration_station_bindings FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.admin_reserve_store_code_v1(p_request_id uuid,p_code text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE actor uuid; result text; candidate text; serial_number bigint;
BEGIN
 PERFORM public.require_brand_admin_v1();
 SELECT id INTO actor FROM users WHERE auth_id=auth.uid() AND is_active;
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'REQUEST_ID_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('store-registration-code',0));
 SELECT code INTO result FROM store_registration_requests WHERE id=p_request_id AND actor_id=actor;
 IF FOUND THEN
  IF nullif(upper(btrim(p_code)),'') IS NOT NULL AND result<>upper(btrim(p_code)) THEN RAISE EXCEPTION 'REQUEST_CODE_FROZEN'; END IF;
  RETURN result;
 END IF;
 IF EXISTS(SELECT 1 FROM store_registration_requests WHERE id=p_request_id) THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
 candidate:=nullif(upper(btrim(p_code)),'');
 IF candidate IS NULL THEN
  -- One aggregate over the occupied namespace; no lookup loop per collision.
  SELECT greatest(nextval('public.store_registration_code_seq'),coalesce(max(substring(occupied.code FROM 3)::bigint),0)+1)
  INTO serial_number FROM (
   SELECT upper(short_code) code FROM restaurants WHERE upper(short_code) ~ '^ST[0-9]{4}$'
   UNION ALL SELECT r.code FROM store_registration_requests r WHERE r.code ~ '^ST[0-9]{4}$'
  ) occupied;
  IF serial_number>9999 THEN RAISE EXCEPTION 'CODE_NAMESPACE_EXHAUSTED'; END IF;
  PERFORM setval('public.store_registration_code_seq',serial_number);
  candidate:='ST'||lpad(serial_number::text,4,'0');
 END IF;
 IF candidate IS NULL THEN RAISE EXCEPTION 'CODE_ALLOCATION_RETRY'; END IF;
 IF candidate !~ '^[A-Z][A-Z0-9]{1,5}$' THEN RAISE EXCEPTION 'ABBREVIATION_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM restaurants WHERE upper(short_code)=candidate)
 OR EXISTS(SELECT 1 FROM store_registration_requests WHERE code=candidate) THEN RAISE EXCEPTION 'ABBREVIATION_EXISTS'; END IF;
 INSERT INTO store_registration_requests(id,actor_id,code) VALUES(p_request_id,actor,candidate);
 RETURN candidate;
END $$;

CREATE FUNCTION public.store_registration_config_v1(p_config jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
DECLARE cfg jsonb; areas jsonb; n integer;
BEGIN
 cfg:=coalesce(p_config,'{}'::jsonb);
 IF jsonb_typeof(cfg)<>'object' OR octet_length(cfg::text)>16384 THEN RAISE EXCEPTION 'REGISTRATION_CONFIG_INVALID'; END IF;
 cfg:=jsonb_build_object('dine_in',true,'kitchens',1,'tray',false,'tablet',false,
  'customer_display',false,'fulfillment_mode','paperless')||cfg;
 IF EXISTS(SELECT 1 FROM jsonb_object_keys(cfg) k WHERE k NOT IN('dine_in','kitchens','tray','tablet','customer_display','fulfillment_mode','areas'))
 OR jsonb_typeof(cfg->'dine_in')<>'boolean' OR jsonb_typeof(cfg->'tray')<>'boolean'
 OR jsonb_typeof(cfg->'tablet')<>'boolean' OR jsonb_typeof(cfg->'customer_display')<>'boolean'
 OR coalesce(cfg->>'kitchens','') !~ '^[1-8]$'
 OR coalesce(cfg->>'fulfillment_mode','') NOT IN('paperless','pos_print') THEN RAISE EXCEPTION 'REGISTRATION_CONFIG_INVALID'; END IF;
 areas:=coalesce(cfg->'areas',CASE WHEN (cfg->>'dine_in')::boolean THEN '[{"code":"HALL","name":"Hall","physical_floor":null}]'::jsonb ELSE '[]'::jsonb END);
 IF jsonb_typeof(areas)<>'array' OR jsonb_array_length(areas)>16 THEN RAISE EXCEPTION 'SERVICE_AREAS_INVALID'; END IF;
 n:=jsonb_array_length(areas);
 IF ((cfg->>'dine_in')::boolean AND n=0) OR (NOT (cfg->>'dine_in')::boolean AND n<>0) THEN RAISE EXCEPTION 'SERVICE_AREAS_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(areas) a WHERE jsonb_typeof(a)<>'object'
  OR coalesce(a->>'code','') !~ '^[A-Z0-9][A-Z0-9_-]{0,15}$'
  OR length(btrim(coalesce(a->>'name',''))) NOT BETWEEN 1 AND 80
  OR (a->>'physical_floor' IS NOT NULL AND length(btrim(a->>'physical_floor')) NOT BETWEEN 1 AND 40))
 OR (SELECT count(DISTINCT a->>'code') FROM jsonb_array_elements(areas) a)<>n THEN RAISE EXCEPTION 'SERVICE_AREAS_INVALID'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('code',a->>'code','name',btrim(a->>'name'),
  'physical_floor',nullif(btrim(a->>'physical_floor'),'')) ORDER BY a->>'code'),'[]') INTO areas FROM jsonb_array_elements(areas) a;
 RETURN cfg||jsonb_build_object('areas',areas);
END $$;
REVOKE ALL ON FUNCTION public.store_registration_config_v1(jsonb) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.admin_preview_store_registration_v1(p_request_id uuid,p_brand_id uuid,p_config jsonb DEFAULT '{}',p_code text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_code text; cfg jsonb; accounts jsonb; brand_code text;
BEGIN
 PERFORM public.require_brand_admin_v1();
 cfg:=public.store_registration_config_v1(p_config);
 SELECT short_code INTO brand_code FROM brands WHERE id=p_brand_id;
 IF brand_code IS NULL THEN RAISE EXCEPTION 'BRAND_ABBREVIATION_REQUIRED'; END IF;
 v_code:=public.admin_reserve_store_code_v1(p_request_id,p_code);
 WITH managers AS MATERIALIZED(
  SELECT DISTINCT ON(q.account_code) q.account_code,q.account_type,q.role,q.display_name,q.scope
  FROM store_fixed_account_requirements q JOIN restaurants r ON r.id=q.store_id
  WHERE r.brand_id=p_brand_id AND q.scope='brand' AND q.is_active ORDER BY q.account_code,q.created_at
 ), templates AS (
  SELECT * FROM managers UNION ALL SELECT lower(brand_code)||'_bm1','brand_manager','brand_admin','Brand Manager','brand' WHERE NOT EXISTS(SELECT 1 FROM managers)
  UNION ALL SELECT lower(v_code)||'_'||suffix,account_type,role,label,'store' FROM (VALUES
   ('sm1','store_manager','store_admin','Store Manager'),('pos1','device_pos','cashier','Cashier'),
   ('pr1','inventory_orderer','inventory_orderer','Requester / Receiver')) t(suffix,account_type,role,label)
  UNION ALL SELECT lower(v_code)||'_kit'||n,'device_kitchen','kitchen','Kitchen '||n,'store' FROM generate_series(1,(cfg->>'kitchens')::integer)n
  UNION ALL SELECT lower(v_code)||'_area_'||lower(a->>'code'),'device_emergency_station','emergency_station',a->>'name','store' FROM jsonb_array_elements(cfg->'areas')a
  UNION ALL SELECT lower(v_code)||'_tray1','device_emergency_station','emergency_station','Tray','store' WHERE (cfg->>'tray')::boolean
  UNION ALL SELECT lower(v_code)||'_tab1','device_tablet','cashier','Tablet','store' WHERE (cfg->>'tablet')::boolean
  UNION ALL SELECT lower(v_code)||'_print','device_print_station','print_station','Print Station','store' WHERE cfg->>'fulfillment_mode'='pos_print'
  UNION ALL SELECT lower(v_code)||'_customer','device_customer_display','customer_display','Customer Display','store' WHERE (cfg->>'customer_display')::boolean
  UNION ALL SELECT lower(v_code)||'_ops1','store_operator','photo_objet_store_operator','Store Operator','store' WHERE EXISTS(SELECT 1 FROM brands WHERE id=p_brand_id AND code='photo_objet')
 ) SELECT jsonb_agg(to_jsonb(t) ORDER BY account_code) INTO accounts FROM templates t;
 IF jsonb_array_length(accounts)>50 THEN RAISE EXCEPTION 'ACCOUNT_LIMIT'; END IF;
 RETURN jsonb_build_object('code',v_code,'config',cfg,'accounts',accounts);
END $$;

ALTER FUNCTION public.admin_create_restaurant_v2(text,text,text,uuid,uuid,text,numeric,uuid) RENAME TO store_create_record_before_registration;
REVOKE ALL ON FUNCTION public.store_create_record_before_registration(text,text,text,uuid,uuid,text,numeric,uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.admin_register_store_v1(p_request_id uuid,p_input jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE input jsonb; preview jsonb; job store_account_onboarding_jobs; store restaurants; actor uuid; v_code text; cfg jsonb;
BEGIN
 PERFORM public.require_brand_admin_v1();
 IF p_request_id IS NULL OR jsonb_typeof(p_input) IS DISTINCT FROM 'object' OR octet_length(p_input::text)>24576 THEN RAISE EXCEPTION 'STORE_INPUT_INVALID'; END IF;
 SELECT id INTO actor FROM users WHERE auth_id=auth.uid() AND is_active;
 PERFORM pg_advisory_xact_lock(hashtextextended('store-onboarding:'||p_request_id,0));
 v_code:=public.admin_reserve_store_code_v1(p_request_id,p_input->>'code');
 cfg:=public.store_registration_config_v1(p_input->'config');
 input:=jsonb_build_object('name',btrim(p_input->>'name'),'address',coalesce(btrim(p_input->>'address'),''),
  'code',v_code,'brand',(p_input->>'brand')::uuid,'entity',(p_input->>'entity')::uuid,
  'mode',coalesce(p_input->>'mode','standard'),'charge',p_input->'charge','config',cfg,
  'account_naming',coalesce(p_input->>'account_naming','configured'),
  'slug',coalesce(nullif(btrim(p_input->>'slug'),''),'store-'||p_request_id), 'office_store_id',p_input->'office_store_id');
 IF length(coalesce(input->>'name','')) NOT BETWEEN 1 AND 120 OR length(input->>'address')>500
 OR input->>'mode' NOT IN('standard','buffet','hybrid')
 OR (input->>'mode'<>'standard' AND coalesce((input->>'charge')::numeric,0)<=0) THEN RAISE EXCEPTION 'STORE_INPUT_INVALID'; END IF;
 SELECT * INTO job FROM store_account_onboarding_jobs WHERE id=p_request_id;
 IF FOUND THEN
  IF job.input<>input OR job.actor_id<>actor THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN job.store_id;
 END IF;
 PERFORM 1 FROM brands WHERE id=(input->>'brand')::uuid FOR UPDATE;
 preview:=public.admin_preview_store_registration_v1(p_request_id,(input->>'brand')::uuid,cfg,v_code);
 IF input->>'account_naming'='legacy' THEN
  IF (cfg->>'kitchens')::int<>1 OR EXISTS(SELECT 1 FROM jsonb_array_elements(cfg->'areas')a WHERE a->>'code' NOT IN('1F','2F','3F')) THEN RAISE EXCEPTION 'LEGACY_ACCOUNT_CONFIG_INVALID'; END IF;
  preview:=preview||jsonb_build_object('accounts',public.admin_preview_store_accounts_v1((input->>'brand')::uuid,v_code,ARRAY(SELECT a->>'code' FROM jsonb_array_elements(cfg->'areas')a)));
 ELSIF input->>'account_naming'<>'configured' THEN RAISE EXCEPTION 'ACCOUNT_NAMING_INVALID'; END IF;
 store:=public.store_create_record_before_registration(input->>'name',input->>'slug',input->>'mode',
  (input->>'entity')::uuid,(input->>'brand')::uuid,input->>'address',(input->>'charge')::numeric,(input->>'office_store_id')::uuid);
 UPDATE restaurants SET short_code=v_code WHERE id=store.id;
 INSERT INTO restaurant_settings(restaurant_id,fulfillment_mode,kds_workflow)
 VALUES(store.id,cfg->>'fulfillment_mode',CASE WHEN (cfg->>'tray')::boolean THEN 'kitchen_tray_floor' ELSE 'kitchen_floor' END)
 ON CONFLICT(restaurant_id) DO UPDATE SET fulfillment_mode=EXCLUDED.fulfillment_mode,kds_workflow=EXCLUDED.kds_workflow;
 INSERT INTO store_service_areas(restaurant_id,stored_code,display_name,physical_floor)
 SELECT store.id,a->>'code',a->>'name',a->>'physical_floor' FROM jsonb_array_elements(cfg->'areas')a;
 INSERT INTO store_service_stations(restaurant_id,code,kind,area_id)
 SELECT store.id,'area:'||stored_code,'floor',id FROM store_service_areas WHERE restaurant_id=store.id
 UNION ALL SELECT store.id,'kitchen:'||n,'kitchen',NULL::uuid FROM generate_series(1,(cfg->>'kitchens')::integer)n
 UNION ALL SELECT store.id,'tray','tray',NULL::uuid WHERE (cfg->>'tray')::boolean;
 INSERT INTO store_registration_station_bindings(restaurant_id,account_code,station_id)
 SELECT store.id,lower(v_code)||CASE s.kind WHEN 'kitchen' THEN '_kit'||CASE WHEN input->>'account_naming'='legacy' THEN '' ELSE split_part(s.code,':',2) END
  WHEN 'tray' THEN '_tray1' ELSE CASE WHEN input->>'account_naming'='legacy' THEN '_floor_' ELSE '_area_' END||lower(a.stored_code) END,s.id
 FROM store_service_stations s LEFT JOIN store_service_areas a ON a.id=s.area_id WHERE s.restaurant_id=store.id;
 INSERT INTO store_account_onboarding_jobs(id,store_id,actor_id,input,accounts) VALUES(p_request_id,store.id,actor,input,preview->'accounts');
 INSERT INTO store_fixed_account_requirements(store_id,account_code,account_type,role,display_name,scope)
 SELECT store.id,t.account_code,t.account_type,t.role,(input->>'name')||' '||t.display_name,t.scope
 FROM jsonb_to_recordset(preview->'accounts')t(account_code text,account_type text,role text,display_name text,scope text);
 UPDATE store_registration_requests SET store_id=store.id WHERE id=p_request_id;
 INSERT INTO audit_logs(actor_id,action,entity_type,entity_id,details)
 VALUES(auth.uid(),'admin_register_store_v1','restaurants',store.id,jsonb_build_object('request_id',p_request_id,'code',v_code,'config',cfg));
 RETURN store.id;
END $$;

-- Old service entry points also produce durable jobs and configuration-driven IDs.
CREATE FUNCTION public.admin_create_restaurant_v2(p_name text,p_slug text,p_operation_mode text,p_tax_entity_id uuid,p_brand_id uuid,
 p_address text DEFAULT NULL,p_per_person_charge numeric DEFAULT NULL,p_office_store_id uuid DEFAULT NULL)
RETURNS public.restaurants LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE store_id uuid; result restaurants; request_id uuid;
BEGIN
 IF nullif(btrim(p_slug),'') IS NULL THEN RAISE EXCEPTION 'REGISTRATION_SLUG_REQUIRED'; END IF;
 request_id:=md5('legacy-registration:'||auth.uid()||':'||btrim(p_slug))::uuid;
 store_id:=public.admin_register_store_v1(request_id,jsonb_build_object('name',p_name,'slug',p_slug,'mode',p_operation_mode,
  'entity',p_tax_entity_id,'brand',p_brand_id,'address',p_address,'charge',p_per_person_charge,'office_store_id',p_office_store_id));
 SELECT * INTO result FROM restaurants WHERE id=store_id; RETURN result;
END $$;

ALTER FUNCTION public.admin_create_store_onboarding_v1(uuid,text,text,text,uuid,uuid,text[],text,numeric) RENAME TO store_create_legacy_onboarding;
REVOKE ALL ON FUNCTION public.store_create_legacy_onboarding(uuid,text,text,text,uuid,uuid,text[],text,numeric) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.admin_create_store_onboarding_v1(p_request_id uuid,p_name text,p_address text,p_code text,p_brand_id uuid,p_tax_entity_id uuid,p_floors text[],p_operation_mode text DEFAULT 'standard',p_per_person_charge numeric DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE areas jsonb;
BEGIN
 PERFORM public.require_brand_admin_v1();
 IF EXISTS(SELECT 1 FROM store_account_onboarding_jobs WHERE id=p_request_id AND NOT input ? 'config') THEN
  RETURN public.store_create_legacy_onboarding(p_request_id,p_name,p_address,p_code,p_brand_id,p_tax_entity_id,p_floors,p_operation_mode,p_per_person_charge);
 END IF;
 IF p_floors IS NULL OR cardinality(p_floors) NOT BETWEEN 1 AND 3 OR array_position(p_floors,NULL) IS NOT NULL OR NOT p_floors <@ ARRAY['1F','2F','3F'] THEN RAISE EXCEPTION 'FLOORS_INVALID'; END IF;
 SELECT jsonb_agg(jsonb_build_object('code',f,'name',f,'physical_floor',f) ORDER BY f) INTO areas FROM (SELECT DISTINCT unnest(p_floors) f)t;
 RETURN public.admin_register_store_v1(p_request_id,jsonb_build_object('name',p_name,'address',p_address,'code',p_code,'brand',p_brand_id,'entity',p_tax_entity_id,'mode',p_operation_mode,'charge',p_per_person_charge,
  'account_naming','legacy','config',jsonb_build_object('areas',areas,'tray',true,'tablet',true,'customer_display',true,'fulfillment_mode','pos_print')));
END $$;
REVOKE ALL ON FUNCTION public.admin_create_store_onboarding_v1(uuid,text,text,text,uuid,uuid,text[],text,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_create_store_onboarding_v1(uuid,text,text,text,uuid,uuid,text[],text,numeric) TO authenticated;

-- Explicit bindings override name inference only for new stores. Preserve the
-- historical JeonGabok floor mapping and retired checker in the legacy branch.
DO $$ DECLARE definition text; BEGIN
 definition:=pg_get_functiondef('public.sync_emergency_station_assignment_for_user()'::regprocedure);
 IF position('store_registration_station_bindings' IN definition)>0 THEN RAISE EXCEPTION 'REGISTRATION_ALREADY_PATCHED'; END IF;
 definition:=replace(definition,'  IF NEW.fixed_account_code IS NULL OR NEW.restaurant_id IS NULL THEN',
 '  SELECT s.kind,a.stored_code INTO v_station,v_floor FROM public.store_registration_station_bindings b JOIN public.store_service_stations s ON s.id=b.station_id LEFT JOIN public.store_service_areas a ON a.id=s.area_id WHERE b.restaurant_id=NEW.restaurant_id AND b.account_code=NEW.fixed_account_code;
  IF FOUND THEN
    INSERT INTO public.emergency_station_assignments(restaurant_id,user_id,station_type,floor_label,is_active) VALUES(NEW.restaurant_id,NEW.id,v_station,v_floor,NEW.is_active)
    ON CONFLICT(restaurant_id,user_id) DO UPDATE SET station_type=EXCLUDED.station_type,floor_label=EXCLUDED.floor_label,is_active=EXCLUDED.is_active,updated_at=now();
    RETURN NEW;
  END IF;
  IF NEW.fixed_account_code IS NULL OR NEW.restaurant_id IS NULL THEN');
 IF position('store_registration_station_bindings' IN definition)=0 THEN RAISE EXCEPTION 'REGISTRATION_TRIGGER_PATCH_MISMATCH'; END IF;
 EXECUTE definition;
END $$;

REVOKE ALL ON FUNCTION public.admin_reserve_store_code_v1(uuid,text),public.admin_preview_store_registration_v1(uuid,uuid,jsonb,text),
 public.admin_register_store_v1(uuid,jsonb),public.admin_create_restaurant_v2(text,text,text,uuid,uuid,text,numeric,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_reserve_store_code_v1(uuid,text),public.admin_preview_store_registration_v1(uuid,uuid,jsonb,text),
 public.admin_register_store_v1(uuid,jsonb),public.admin_create_restaurant_v2(text,text,text,uuid,uuid,text,numeric,uuid) TO authenticated;
COMMIT;
